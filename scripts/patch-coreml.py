"""Patch Immich's ONNX Runtime sessions for reliable, fast CoreML use.

The upstream CoreML default (MLProgram for every ONNX model) is not valid for
all of Immich's model shapes.  Keep MLProgram for static models, but:

* disable MatMulAddFusion for CLIP MLProgram sessions.  ORT 1.26
  otherwise writes generated Gemm constants into model.mil as multi-gigabyte
  text immediates;
* keep SO400M's externally-stored textual tower on ORT CPU because ORT's
  CoreML graph builder loses the external initializer path;
* require static inputs for MLProgram sessions;
* make the face detector's always-640x640 input static in a derived ONNX file;
* use the older NeuralNetwork format for dynamically batched face recognition
  and dynamic-size OCR models; and
* launch Uvicorn without Gunicorn's prefork on Darwin/CoreML, because MPS
  cannot reliably contact MTLCompilerService from the forked worker; and
* retain MACHINE_LEARNING_DISABLE_COREML as a CPU escape hatch.

This script deliberately uses exact source replacements.  A failed match is a
request to re-audit the patch when upgrading Immich, not something to paper
over with a fuzzy edit.
"""

import sys
from pathlib import Path


def replace(path: Path, description: str, old: str, new: str) -> None:
    source = path.read_text()
    if old not in source:
        raise SystemExit(
            f"{path}: expected {description} not found.\n"
            "Upstream may have restructured this; re-check the file at the "
            "target tag before adapting this patch."
        )
    path.write_text(source.replace(old, new, 1))


def patch_constants(root: Path) -> None:
    path = root / "immich_ml/models/constants.py"
    replace(
        path,
        "config import",
        "from immich_ml.config import clean_name\n",
        "import os\n\nfrom immich_ml.config import clean_name\n",
    )
    replace(
        path,
        "CoreML provider entry",
        '    "CoreMLExecutionProvider",\n',
        '    *([] if os.environ.get("MACHINE_LEARNING_DISABLE_COREML") else ["CoreMLExecutionProvider"]),\n',
    )


def patch_ort(root: Path) -> None:
    path = root / "immich_ml/sessions/ort.py"
    replace(path, "typing import", "from typing import Any\n", "from typing import Any, Literal\n")
    replace(
        path,
        "CoreML format type insertion point",
        "MigraphxInputSignature = tuple[tuple[str, str, tuple[int, ...]], ...]\n",
        'CoreMLModelFormat = Literal["MLProgram", "NeuralNetwork"]\n'
        "MigraphxInputSignature = tuple[tuple[str, str, tuple[int, ...]], ...]\n",
    )
    replace(
        path,
        "OrtSession constructor",
        """        provider_options: list[dict[str, Any]] | None = None,
        sess_options: ort.SessionOptions | None = None,
    ):
        self.model_path = Path(model_path)
        self.providers = providers if providers is not None else self._providers_default
""",
        """        provider_options: list[dict[str, Any]] | None = None,
        sess_options: ort.SessionOptions | None = None,
        coreml_model_format: CoreMLModelFormat = "MLProgram",
        coreml_enabled: bool = True,
        coreml_disable_matmul_add_fusion: bool = False,
    ):
        self.model_path = Path(model_path)
        self.coreml_model_format = coreml_model_format
        self.coreml_enabled = coreml_enabled
        self.coreml_disable_matmul_add_fusion = coreml_disable_matmul_add_fusion
        self.providers = providers if providers is not None else self._providers_default
""",
    )
    replace(
        path,
        "default provider filtering",
        """        return [provider for provider in SUPPORTED_PROVIDERS if provider in available_providers]
""",
        """        return [
            provider
            for provider in SUPPORTED_PROVIDERS
            if provider in available_providers and (self.coreml_enabled or provider != "CoreMLExecutionProvider")
        ]
""",
    )
    replace(
        path,
        "CoreML provider options",
        """                    options = {
                        "ModelFormat": "MLProgram",
                        "MLComputeUnits": "ALL",
                        "SpecializationStrategy": "FastPrediction",
                        "AllowLowPrecisionAccumulationOnGPU": "1",
                        "ModelCacheDirectory": (self.model_path.parent / "coreml").as_posix(),
                    }
""",
        """                    options = {
                        "ModelFormat": self.coreml_model_format,
                        "MLComputeUnits": "ALL",
                        "SpecializationStrategy": "FastPrediction",
                        "AllowLowPrecisionAccumulationOnGPU": "1",
                        "ModelCacheDirectory": (self.model_path.parent / "coreml").as_posix(),
                    }
                    if self.coreml_model_format == "MLProgram":
                        options["RequireStaticInputShapes"] = "1"
""",
    )
    replace(
        path,
        "session-options return",
        """        if sess_options.inter_op_num_threads > 1:
            sess_options.execution_mode = ort.ExecutionMode.ORT_PARALLEL

        return sess_options
""",
        """        if sess_options.inter_op_num_threads > 1:
            sess_options.execution_mode = ort.ExecutionMode.ORT_PARALLEL

        if (
            "CoreMLExecutionProvider" in self.providers
            and self.coreml_model_format == "MLProgram"
            and self.coreml_disable_matmul_add_fusion
        ):
            # ORT 1.26's MatMulAddFusion turns initializer-backed weights into
            # generated Gemm constants. CoreML serializes those as ASCII in
            # model.mil, making SO400M a 6.5 GB program that cannot compile.
            # https://github.com/microsoft/onnxruntime/issues/32212
            sess_options.add_session_config_entry(
                "optimization.disable_specified_optimizers",
                "MatMulAddFusion",
            )

        return sess_options
""",
    )


def patch_base(root: Path) -> None:
    path = root / "immich_ml/models/base.py"
    replace(
        path,
        "OrtSession import",
        "from immich_ml.sessions.ort import OrtSession\n",
        "from immich_ml.sessions.ort import CoreMLModelFormat, OrtSession\n",
    )
    replace(
        path,
        "session factory",
        """    def _make_session(self, model_path: Path) -> ModelSession:
        if not model_path.is_file():
            raise FileNotFoundError(f"Model file not found: {model_path}")

        match model_path.suffix:
            case ".armnn":
                session: ModelSession = AnnSession(model_path)
            case ".onnx":
                session = OrtSession(model_path)
""",
        """    def _make_session(
        self,
        model_path: Path,
        *,
        coreml_model_format: CoreMLModelFormat = "MLProgram",
        coreml_enabled: bool = True,
        coreml_disable_matmul_add_fusion: bool = False,
    ) -> ModelSession:
        if not model_path.is_file():
            raise FileNotFoundError(f"Model file not found: {model_path}")

        match model_path.suffix:
            case ".armnn":
                session: ModelSession = AnnSession(model_path)
            case ".onnx":
                session = OrtSession(
                    model_path,
                    coreml_model_format=coreml_model_format,
                    coreml_enabled=coreml_enabled,
                    coreml_disable_matmul_add_fusion=coreml_disable_matmul_add_fusion,
                )
""",
    )


def patch_clip(root: Path) -> None:
    visual = root / "immich_ml/models/clip/visual.py"
    replace(
        visual,
        "CLIP visual prediction method",
        """    def _predict(self, inputs: Image.Image | bytes) -> str:
""",
        """    def _load(self) -> ModelSession:
        return self._make_session(self.model_path, coreml_disable_matmul_add_fusion=True)

    def _predict(self, inputs: Image.Image | bytes) -> str:
""",
    )

    textual = root / "immich_ml/models/clip/textual.py"
    replace(
        textual,
        "CLIP textual session load",
        """    def _load(self) -> ModelSession:
        session = super()._load()
""",
        """    def _load(self) -> ModelSession:
        # The SO400M text export stores 2.8 GB of initializers in external
        # files. ORT 1.26's CoreML graph builder loses their model path while
        # transforming the graph, so both MLProgram and NeuralNetwork fail.
        # Text encoding happens once per search; keep only this tower on CPU.
        session = self._make_session(
            self.model_path,
            coreml_enabled=not self.model_name.startswith("ViT-SO400M-"),
            coreml_disable_matmul_add_fusion=True,
        )
""",
    )


def patch_face_detector(root: Path) -> None:
    path = root / "immich_ml/models/facial_recognition/detection.py"
    replace(
        path,
        "face detector imports",
        """from typing import Any

import numpy as np
from insightface.model_zoo import RetinaFace
""",
        """from hashlib import sha256
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any

import numpy as np
import onnx
import onnxruntime as ort
from google.protobuf.message import DecodeError
from insightface.model_zoo import RetinaFace
""",
    )
    replace(
        path,
        "face detector model imports",
        """from immich_ml.models.base import InferenceModel
from immich_ml.models.transforms import decode_cv2
from immich_ml.schemas import FaceDetectionOutput, ModelSession, ModelTask, ModelType
""",
        """from immich_ml.config import log
from immich_ml.models.base import InferenceModel
from immich_ml.models.constants import SUPPORTED_PROVIDERS
from immich_ml.models.transforms import decode_cv2
from immich_ml.schemas import FaceDetectionOutput, ModelFormat, ModelSession, ModelTask, ModelType
""",
    )
    replace(
        path,
        "face detector loader",
        """    def _load(self) -> ModelSession:
        session = self._make_session(self.model_path)
        self.model = RetinaFace(session=session)
""",
        """    def _load(self) -> ModelSession:
        model_path = self.model_path
        if (
            isinstance(model_path, Path)
            and self.model_format == ModelFormat.ONNX
            and "CoreMLExecutionProvider" in SUPPORTED_PROVIDERS
            and "CoreMLExecutionProvider" in ort.get_available_providers()
        ):
            model_path = self._coreml_static_model_path()

        session = self._make_session(model_path)
        self.model = RetinaFace(session=session)
""",
    )
    replace(
        path,
        "face detector configure method",
        """    def configure(self, **kwargs: Any) -> None:
        self.model.det_thresh = kwargs.pop("minScore", self.model.det_thresh)
""",
        """    def configure(self, **kwargs: Any) -> None:
        self.model.det_thresh = kwargs.pop("minScore", self.model.det_thresh)

    def _coreml_static_model_path(self) -> Path:
        \"\"\"Return a derived 640x640 model so MLProgram can use GPU/ANE.\"\"\"
        source_digest = sha256(self.model_path.read_bytes()).hexdigest()[:32]
        cache_key = f"ImmichFaceDetector640v1{source_digest}"
        static_path = self.model_path.with_name("model_coreml_static.onnx")

        if static_path.is_file():
            try:
                cached = onnx.load(static_path, load_external_data=False)
                if any(prop.key == "CACHE_KEY" and prop.value == cache_key for prop in cached.metadata_props):
                    return static_path
            except (DecodeError, OSError, RuntimeError, ValueError):
                log.warning(f"Ignoring invalid static CoreML face detector at {static_path}")

        proto = onnx.load(self.model_path)
        input_shape = proto.graph.input[0].type.tensor_type.shape.dim
        if len(input_shape) != 4:
            raise ValueError(f"Expected a rank-4 face detector input, got rank {len(input_shape)}")
        for dim, value in zip(input_shape, (1, 3, 640, 640)):
            dim.ClearField("dim_param")
            dim.dim_value = value

        metadata = next((prop for prop in proto.metadata_props if prop.key == "CACHE_KEY"), None)
        if metadata is None:
            metadata = proto.metadata_props.add()
            metadata.key = "CACHE_KEY"
        metadata.value = cache_key

        log.info(f"Writing static CoreML face detector to {static_path}")
        with NamedTemporaryFile(
            dir=static_path.parent,
            prefix=".model_coreml_static.",
            suffix=".onnx",
            delete=False,
        ) as tmp:
            tmp_path = Path(tmp.name)
        try:
            onnx.save(proto, tmp_path)
            tmp_path.replace(static_path)
        finally:
            tmp_path.unlink(missing_ok=True)
        return static_path
""",
    )


def patch_dynamic_models(root: Path) -> None:
    recognition = root / "immich_ml/models/facial_recognition/recognition.py"
    source = recognition.read_text()
    old = "session = self._make_session(self.model_path)"
    if source.count(old) != 2:
        raise SystemExit(f"{recognition}: expected exactly two face-recognition session creations")
    recognition.write_text(source.replace(old, 'session = self._make_session(self.model_path, coreml_model_format="NeuralNetwork")'))

    for relative in ("immich_ml/models/ocr/detection.py", "immich_ml/models/ocr/recognition.py"):
        path = root / relative
        replace(
            path,
            "OCR OrtSession creation",
            "OrtSession(self.model_path)",
            'OrtSession(self.model_path, coreml_model_format="NeuralNetwork")',
        )


def patch_entrypoint(root: Path) -> None:
    path = root / "immich_ml/__main__.py"
    replace(
        path,
        "entrypoint imports",
        """import os
import signal
import subprocess
""",
        """import os
import signal
import subprocess
import sys
""",
    )
    replace(
        path,
        "Gunicorn command",
        """try:
    with subprocess.Popen(
        [
            "python",
            "-m",
            "gunicorn",
            "immich_ml.main:app",
            "-k",
            "immich_ml.config.CustomUvicornWorker",
            "-c",
            module_dir / "gunicorn_conf.py",
            "-b",
            bind_address,
            "-w",
            str(settings.workers),
            "-t",
            str(settings.worker_timeout),
            "--log-config-json",
            module_dir / "log_conf.json",
            "--keep-alive",
            str(settings.http_keepalive_timeout_s),
            "--graceful-timeout",
            "10",
            "--no-control-socket",
        ],
    ) as cmd:
""",
        """command: list[str | Path]
if sys.platform == "darwin" and not os.getenv("MACHINE_LEARNING_DISABLE_COREML"):
    # CoreML's NeuralNetwork/MPS path can abort when initialized in Gunicorn's
    # forked worker because it cannot contact MTLCompilerService. Uvicorn uses
    # the current process for one worker and spawn for multiple workers.
    command = [
        "python",
        "-m",
        "uvicorn",
        "immich_ml.main:app",
        "--host",
        non_prefixed_settings.immich_host,
        "--port",
        str(non_prefixed_settings.immich_port),
        "--log-config",
        module_dir / "log_conf.json",
        "--timeout-keep-alive",
        str(settings.http_keepalive_timeout_s),
    ]
    if settings.workers > 1:
        command.extend(("--workers", str(settings.workers)))
else:
    command = [
        "python",
        "-m",
        "gunicorn",
        "immich_ml.main:app",
        "-k",
        "immich_ml.config.CustomUvicornWorker",
        "-c",
        module_dir / "gunicorn_conf.py",
        "-b",
        bind_address,
        "-w",
        str(settings.workers),
        "-t",
        str(settings.worker_timeout),
        "--log-config-json",
        module_dir / "log_conf.json",
        "--keep-alive",
        str(settings.http_keepalive_timeout_s),
        "--graceful-timeout",
        "10",
        "--no-control-socket",
    ]

try:
    with subprocess.Popen(command) as cmd:
""",
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} MACHINE_LEARNING_SOURCE_DIR")
    root = Path(sys.argv[1])
    patch_constants(root)
    patch_ort(root)
    patch_base(root)
    patch_clip(root)
    patch_face_detector(root)
    patch_dynamic_models(root)
    patch_entrypoint(root)


if __name__ == "__main__":
    main()
