"""Make onnxruntime's CoreML execution provider switchable off at runtime.

On Apple Silicon the CoreML EP is not reliable for Immich's models:

  * Large models can wedge its MLProgram compile. ViT-SO400M-16-SigLIP2-512
    serialises ~99% of its weights as text immediates into model.mil (6.3 GB of
    ASCII hex floats, against a 9 MB weights blob), and coremlcompiler never
    finishes parsing it.
  * Smaller models compile, but MetalPerformanceShaders then hard-aborts the
    worker mid-inference:

        Unable to reach MTLCompilerService ... error 3 - No such process
        MPSKernelDAG.mm:1382: failed assertion
        Worker (pid:NNNNN) was sent SIGABRT!

    gunicorn respawns, the model is reloaded from cache, a few images go
    through, and it aborts again -- so most wall-clock goes to model loading.
    Reproduced at smart-search concurrency 12, 6 and 2 alike, so it is not
    contention.

Upstream has no setting for this: the provider list is get_available_providers()
intersected with the hardcoded SUPPORTED_PROVIDERS, then passed straight to the
session. So gate the CoreML entry on an env var, leaving the default behaviour
untouched:

    MACHINE_LEARNING_DISABLE_COREML=1   ->  fall through to CPUExecutionProvider

Drop this patch once onnxruntime fixes the MPS assertion; re-test by simply
unsetting the variable.
"""

import sys

OLD_IMPORT = "from immich_ml.config import clean_name\n"
NEW_IMPORT = "import os\n\nfrom immich_ml.config import clean_name\n"

OLD_PROVIDER = '    "CoreMLExecutionProvider",\n'
NEW_PROVIDER = (
    '    *([] if os.environ.get("MACHINE_LEARNING_DISABLE_COREML")'
    ' else ["CoreMLExecutionProvider"]),\n'
)


def main() -> None:
    path = sys.argv[1]
    source = open(path).read()

    for name, needle in (("import block", OLD_IMPORT), ("CoreML provider entry", OLD_PROVIDER)):
        if needle not in source:
            raise SystemExit(
                f"{path}: expected {name} not found.\n"
                "Upstream may have restructured this; re-check the file at the "
                "target tag before dropping or adapting this patch."
            )

    source = source.replace(OLD_IMPORT, NEW_IMPORT, 1)
    source = source.replace(OLD_PROVIDER, NEW_PROVIDER, 1)
    open(path, "w").write(source)


if __name__ == "__main__":
    main()
