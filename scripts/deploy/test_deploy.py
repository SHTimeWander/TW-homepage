"""Exercise deployment failure recovery without needing a Docker daemon."""

import gzip
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("deploy-remote.sh")
APP = "tw-homepage"
OLD_IMAGE = f"{APP}:old"
NEW_IMAGE = f"{APP}:new"

MOCK_DOCKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

path = Path(os.environ["DOCKER_STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
state["commands"].append(args)
containers = state["containers"]
scenario = state["scenario"]
status = 0

if args[0] == "info":
    pass
elif args[:2] == ["container", "inspect"]:
    status = 0 if args[-1] in containers else 1
elif args[0] == "inspect":
    item = containers[args[-1]]
    field = args[2]
    if "Labels" in field:
        print(item["owner"])
    elif "Config.Image" in field:
        print(item["image"])
    elif "State.Running" in field:
        print(str(item["running"]).lower())
    elif "Health.Status" in field:
        print("unhealthy" if scenario == "unhealthy" else "healthy")
    else:
        raise AssertionError(args)
elif args[0] == "load":
    sys.stdin.buffer.read()
    status = 1 if scenario == "load_failure" else 0
elif args[:2] == ["image", "inspect"]:
    print("linux/amd64")
elif args[:2] == ["image", "rm"]:
    pass
elif args[0] == "rename":
    if args[2] in containers:
        status = 1
    else:
        containers[args[2]] = containers.pop(args[1])
elif args[0] == "stop":
    containers[args[-1]]["running"] = False
    status = 1 if scenario == "stop_failure" else 0
elif args[0] == "start":
    containers[args[-1]]["running"] = True
elif args[0] == "rm":
    containers.pop(args[-1], None)
elif args[0] == "run":
    name = args[args.index("--name") + 1]
    containers[name] = {"image": args[-1], "running": scenario != "run_failure", "owner": name}
    status = 1 if scenario == "run_failure" else 0
else:
    raise AssertionError(args)

path.write_text(json.dumps(state))
sys.exit(status)
'''


def container(image=OLD_IMAGE, running=True, owner=APP):
    return {"image": image, "running": running, "owner": owner}


class DeploymentTests(unittest.TestCase):
    def deploy(self, scenario="healthy", existing=None, image=NEW_IMAGE):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload"
            payload.mkdir()
            (payload / "deploy.env").write_text(
                f"APP_NAME={APP}\nAPP_DEPLOY_PATH={shlex.quote(str(root / 'app'))}\n"
                f"APP_PORT=3000\nIMAGE={image}\n"
            )
            (payload / "app.env").write_text("HOMEPAGE_ALLOWED_HOSTS=localhost:3000\n")
            with gzip.open(payload / "image.tar.gz", "wb") as archive:
                archive.write(b"test image")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name, contents in {"docker": MOCK_DOCKER, "flock": "#!/bin/sh\nexit 0\n"}.items():
                executable = bin_dir / name
                executable.write_text(contents)
                executable.chmod(0o700)
            state_file = root / "state.json"
            state_file.write_text(json.dumps({
                "containers": existing or {}, "scenario": scenario, "commands": [],
            }))
            result = subprocess.run(
                ["bash", str(SCRIPT), str(payload)],
                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "DOCKER_STATE": str(state_file)},
                capture_output=True, text=True, timeout=10,
            )
            return result, json.loads(state_file.read_text())

    def test_first_deployment(self):
        result, state = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["containers"], {APP: container(NEW_IMAGE)})

    def test_successful_replacement(self):
        result, state = self.deploy(existing={APP: container()})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["containers"], {APP: container(NEW_IMAGE)})
        self.assertIn(["image", "rm", OLD_IMAGE], state["commands"])

    def test_failures_restore_running_container(self):
        for scenario in ("load_failure", "run_failure", "unhealthy", "stop_failure"):
            with self.subTest(scenario=scenario):
                result, state = self.deploy(scenario, {APP: container()})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["containers"], {APP: container()})
                self.assertNotIn(["image", "rm", OLD_IMAGE], state["commands"])

    def test_first_deployment_failure_removes_failed_container(self):
        result, state = self.deploy("unhealthy")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["containers"], {})

    def test_stopped_container_remains_stopped_after_rollback(self):
        previous = {APP: container(running=False)}
        result, state = self.deploy("unhealthy", previous)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["containers"], previous)

    def test_failed_same_commit_redeployment_keeps_image(self):
        result, state = self.deploy("unhealthy", {APP: container()}, OLD_IMAGE)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["containers"], {APP: container()})
        self.assertNotIn(["image", "rm", OLD_IMAGE], state["commands"])

    def test_does_not_replace_unrelated_container(self):
        previous = {APP: container(owner="another-application")}
        result, state = self.deploy(existing=previous)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["containers"], previous)
        self.assertFalse(any(args[0] in ("stop", "rename", "rm", "run") for args in state["commands"]))

    def test_does_not_overwrite_interrupted_deployment_backup(self):
        previous = {f"{APP}-rollback": container()}
        result, state = self.deploy(existing=previous)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["containers"], previous)


if __name__ == "__main__":
    unittest.main()
