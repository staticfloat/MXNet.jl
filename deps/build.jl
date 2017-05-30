using Compat
import JSON

################################################################################
# First try to detect and load existing libmxnet
################################################################################
libmxnet_detected = false
libmxnet_curr_ver = "master"
curr_win = "20170502"

if haskey(ENV, "MXNET_HOME")
  info("MXNET_HOME environment detected: $(ENV["MXNET_HOME"])")
  info("Trying to load existing libmxnet...")
  lib = Libdl.find_library(["libmxnet", "libmxnet.so"], ["$(ENV["MXNET_HOME"])/lib"])
  if !isempty(lib)
    info("Existing libmxnet detected at $lib, skip building...")
    libmxnet_detected = true
  else
    info("Failed to load existing libmxnet, trying to build from source...")
  end
end

# Try to find cuda
CUDAPATHS = String[]
if haskey(ENV, "CUDA_HOME")
  push!(CUDAPATHS, joinpath(ENV["CUDA_HOME"], "lib64"))
elseif is_linux()
  append!(CUDAPATHS, ["/opt/cuda/lib64", "/usr/local/cuda/lib64"])
end

if is_unix()
  try
    push!(CUDAPATHS, replace(strip(readstring(`which nvcc`)), "bin/nvcc", "lib64"))
  end
end

HAS_CUDA = false
let cudalib = Libdl.find_library(["libcuda", "nvcuda.dll"], CUDAPATHS)
  HAS_CUDA = Libdl.dlopen_e(cudalib) != C_NULL
end

if !HAS_CUDA && is_windows()
  # TODO: this needs to be improved.
  try
    run(`nvcc --version`)
    HAS_CUDA = true
  end
end

if HAS_CUDA
  info("Found a CUDA installation.")
else
  info("Did not find a CUDA installation, using CPU-only version of MXNet.")
end

using BinDeps
@BinDeps.setup
if !libmxnet_detected
  if is_windows()
    if Sys.ARCH != :x86_64
      info("Prebuilt windows binaries are only available on 64bit. You will have to built MXNet yourself.")
      return
    end
    info("Downloading pre-built packages for Windows.")
    base_url = "https://github.com/yajiedesign/mxnet/releases/download/weekly_binary_build/prebuildbase_win10_x64_vc14.7z"

    if libmxnet_curr_ver == "master"
      # download_cmd uses powershell 2, but we need powershell 3 to do this
      run(`powershell -NoProfile -Command Invoke-WebRequest -Uri "https://api.github.com/repos/yajiedesign/mxnet/releases/latest" -OutFile "mxnet.json"`)
      curr_win = JSON.parsefile("mxnet.json")["tag_name"]
      info("Can't use MXNet master on Windows, using latest binaries from $curr_win.")
    end
    # TODO: Get url from JSON.
    name = "mxnet_x64_vc14_$(HAS_CUDA ? "gpu" : "cpu").7z"
    package_url = "https://github.com/yajiedesign/mxnet/releases/download/$(curr_win)/$(curr_win)_$(name)"

    exe7z = joinpath(JULIA_HOME, "7z.exe")

    run(download_cmd(base_url, "mxnet_base.7z"))
    run(`$exe7z x mxnet_base.7z -y -ousr`)
    run(`cmd /c copy "usr\\3rdparty\\openblas\\bin\\*.dll" "usr\\lib"`)
    run(`cmd /c copy "usr\\3rdparty\\opencv\\*.dll" "usr\\lib"`)

    run(download_cmd(package_url, "mxnet.7z"))
    run(`$exe7z x mxnet.7z -y -ousr`)
    run(`cmd /c copy "usr\\build\\*.dll" "usr\\lib"`)

    return
  end

  ################################################################################
  # If not found, try to build automatically using BinDeps
  ################################################################################

  blas_path = Libdl.dlpath(Libdl.dlopen(Base.libblas_name))

  if VERSION >= v"0.5.0-dev+4338"
    blas_vendor = Base.BLAS.vendor()
  else
    blas_vendor = Base.blas_vendor()
  end

  ilp64 = ""
  if blas_vendor == :openblas64
    ilp64 = "-DINTERFACE64"
  end

  if blas_vendor == :unknown
    info("Julia is built with an unkown blas library ($blas_path).")
    info("Attempting build without reusing the blas library")
    USE_JULIA_BLAS = false
  elseif !(blas_vendor in (:openblas, :openblas64))
    info("Unsure if we can build against $blas_vendor.")
    info("Attempting build anyway.")
    USE_JULIA_BLAS = true
  else
    USE_JULIA_BLAS = true
  end

  blas_name = blas_vendor == :openblas64 ? "openblas" : string(blas_vendor)
  MSHADOW_LDFLAGS = "MSHADOW_LDFLAGS=-lm $blas_path"

  #--------------------------------------------------------------------------------
  # Build libmxnet
  mxnet = library_dependency("mxnet", aliases=["mxnet", "libmxnet", "libmxnet.so"])

  _prefix = joinpath(BinDeps.depsdir(mxnet), "usr")
  _srcdir = joinpath(BinDeps.depsdir(mxnet), "src")
  _mxdir  = joinpath(_srcdir, "mxnet")
  _libdir = joinpath(_prefix, "lib")
  # We have do eagerly delete the installed libmxnet.so
  # Otherwise we won't rebuild on an update.
  run(`rm -f $_libdir/libmxnet.so`)
  provides(BuildProcess,
    (@build_steps begin
      CreateDirectory(_srcdir)
      CreateDirectory(_libdir)
      @build_steps begin
        BinDeps.DirectoryRule(_mxdir, @build_steps begin
          ChangeDirectory(_srcdir)
          `git clone --recursive https://github.com/dmlc/mxnet`
        end)
        @build_steps begin
          ChangeDirectory(_mxdir)
          `git -C mshadow checkout -- make/mshadow.mk`
          `git fetch`
          `git checkout $libmxnet_curr_ver`
          `git submodule update --init`
          `make clean`
          `sed -i -s "s/MSHADOW_CFLAGS = \(.*\)/MSHADOW_CFLAGS = \1 $ilp64/" mshadow/make/mshadow.mk`
        end
        FileRule(joinpath(_mxdir, "config.mk"), @build_steps begin
          ChangeDirectory(_mxdir)
          if is_apple()
            `cp make/osx.mk config.mk`
          else
            `cp make/config.mk config.mk`
          end
          `sed -i -s 's/USE_OPENCV = 1/USE_OPENCV = 0/' config.mk`
          if HAS_CUDA
            `sed -i -s 's/USE_CUDA = 0/USE_CUDA = 1/' config.mk`
            if haskey(ENV, "CUDA_HOME")
              `sed -i -s 's/USE_CUDA_PATH = NULL/USE_CUDA_PATH = $(ENV["CUDA_HOME"])/' config.mk`
            end
          end
        end)
        @build_steps begin
          ChangeDirectory(_mxdir)
          `cp ../../cblas.h include/cblas.h`
          if USE_JULIA_BLAS
            `make -j$(min(Sys.CPU_CORES,8)) USE_BLAS=$blas_name $MSHADOW_LDFLAGS`
          else
            `make -j$(min(Sys.CPU_CORES,8))`
          end
        end
        FileRule(joinpath(_libdir, "libmxnet.so"), @build_steps begin
          `cp $_mxdir/lib/libmxnet.so $_libdir/`
        end)
      end
    end), mxnet, installed_libpath=_libdir)

  @BinDeps.install Dict(:mxnet => :mxnet)
end
