# Instructions for running GPUscout

- Run `install/GPUscout` instead of `GPUscout.sh` after install

- Run `sudo -s` to enter sudo shell in current directory to avoid permission errors like

```shell
pc_sampling_continuous.cpp:582: error: function cuptiGetLastError() failed with error CUPTI_ERROR_INSUFFICIENT_PRIVILEGES.
```

- Run

```shell
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:$LD_LIBRARY_PATH
export PATH=/usr/local/cuda/bin:$PATH
```

 to set up the environment variables if `libcupti.so` not found error occurs

- `./GPUscout -e ../../cuda-exp/add -c ../../cuda-exp/cubin-add` (Example)
