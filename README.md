Experimental CUDA acceleration for `libfive`

Not yet ready for public consumption!

# Building
First, build the `libfive` submodule in a folder named `build`.

Then,
```
mkdir build
cd build
env CUDACXX=/usr/local/cuda/bin/nvcc cmake -GNinja ..
```
