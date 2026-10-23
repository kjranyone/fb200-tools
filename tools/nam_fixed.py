"""Compatibility entry point for the fixed-model research converter."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from fb200 import nam_model

DILATIONS = nam_model.DILATIONS
KERNELS = nam_model.KERNELS
emit = nam_model.emit
main = nam_model.main
validate = nam_model.validate

if __name__ == "__main__":
    main()
