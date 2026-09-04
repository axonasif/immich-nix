import builtins
import importlib.util
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PATCH_PATH = ROOT / "scripts/patch-coreml.py"
UPSTREAM_PATH = ROOT / "upstream/immich"
ENTRYPOINT_GIT_PATH = "machine-learning/immich_ml/__main__.py"


def load_patch_module() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("patch_coreml", PATCH_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeProcess:
    def __init__(self, returncode: int = 0, wait_error: BaseException | None = None) -> None:
        self.returncode = returncode
        self.wait_error = wait_error
        self.signals: list[int] = []

    def __enter__(self) -> "FakeProcess":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def wait(self) -> None:
        if self.wait_error is not None:
            raise self.wait_error

    def send_signal(self, sig: int) -> None:
        self.signals.append(sig)


class ProcessFactory:
    def __init__(self, *processes: FakeProcess) -> None:
        self.processes = iter(processes)
        self.calls: list[list[str | Path]] = []

    def __call__(self, command: list[str | Path]) -> FakeProcess:
        self.calls.append(command)
        return next(self.processes)


class CoreMLEntrypointTest(unittest.TestCase):
    def setUp(self) -> None:
        patch_module = load_patch_module()
        self.tempdir = tempfile.TemporaryDirectory()
        machine_learning = Path(self.tempdir.name) / "machine-learning"
        package = machine_learning / "immich_ml"
        package.mkdir(parents=True)
        self.entrypoint = package / "__main__.py"
        source = subprocess.check_output(
            ["git", "-C", str(UPSTREAM_PATH), "show", f"HEAD:{ENTRYPOINT_GIT_PATH}"],
            text=True,
        )
        self.entrypoint.write_text(source)
        patch_module.patch_entrypoint(machine_learning)

        self.log = mock.Mock()
        self.config = types.ModuleType("immich_ml.config")
        self.config.log = self.log
        self.config.non_prefixed_settings = types.SimpleNamespace(
            immich_host="127.0.0.1",
            immich_port=3003,
        )
        self.config.settings = types.SimpleNamespace(
            workers=1,
            worker_timeout=300,
            http_keepalive_timeout_s=2,
        )
        self.package = types.ModuleType("immich_ml")
        self.package.__path__ = [str(package)]

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_entrypoint(
        self,
        factory: ProcessFactory,
        *,
        disable_coreml: str = "",
    ) -> tuple[mock.Mock, mock.Mock]:
        source = compile(self.entrypoint.read_text(), self.entrypoint, "exec")
        sleep = mock.Mock()
        exit_mock = mock.Mock(side_effect=SystemExit)
        modules = {"immich_ml": self.package, "immich_ml.config": self.config}
        namespace = {
            "__file__": str(self.entrypoint),
            "__name__": "immich_ml.__main__",
            "__package__": "immich_ml",
        }

        with (
            mock.patch.dict(sys.modules, modules),
            mock.patch.object(sys, "platform", "darwin"),
            mock.patch.dict(
                "os.environ",
                {"MACHINE_LEARNING_DISABLE_COREML": disable_coreml},
                clear=False,
            ),
            mock.patch.object(subprocess, "Popen", factory),
            mock.patch("time.sleep", sleep),
            mock.patch.object(builtins, "exit", exit_mock),
        ):
            with self.assertRaises(SystemExit):
                exec(source, namespace)
        return sleep, exit_mock

    def test_restarts_after_clean_exit_and_stops_after_error(self) -> None:
        factory = ProcessFactory(FakeProcess(0), FakeProcess(1))

        sleep, exit_mock = self.run_entrypoint(factory)

        self.assertEqual(len(factory.calls), 2)
        sleep.assert_called_once_with(1)
        self.assertEqual(
            self.log.info.call_args_list.count(
                mock.call("Machine-learning worker exited after inactivity; restarting.")
            ),
            1,
        )
        exit_mock.assert_called_once_with(1)

    def test_forwards_keyboard_interrupt_to_worker(self) -> None:
        process = FakeProcess(0, KeyboardInterrupt())
        factory = ProcessFactory(process)

        sleep, exit_mock = self.run_entrypoint(factory)

        self.assertEqual(process.signals, [signal.SIGINT])
        sleep.assert_not_called()
        exit_mock.assert_called_once_with(0)

    def test_does_not_supervise_gunicorn_path(self) -> None:
        factory = ProcessFactory(FakeProcess(0))

        sleep, exit_mock = self.run_entrypoint(factory, disable_coreml="1")

        self.assertEqual(len(factory.calls), 1)
        self.assertIn("gunicorn", factory.calls[0])
        sleep.assert_not_called()
        exit_mock.assert_called_once_with(0)


if __name__ == "__main__":
    unittest.main()
