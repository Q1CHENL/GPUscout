#!/bin/bash

# Define the usage function
usage() {
    echo "Usage: $0 [-h] [--dry_run] [--verbose] -e executable [-c directory] [--args] [--kernels list] [--analysis list] [--nsys-hotspot-kernels [num]]"
    echo "  -h | --help : Display this help."
    echo "  --dry_run : performs only dry_run. A --dry_run will only analyse the SASS instructions. --dry_run will neither read warp stalls nor Nsight metrics "
    echo "  -v | --verbose : print more verbose output. "
    echo "  -e | --executable : Path to the executable (compiled with nvcc)."
    echo "  -c | --cubin : Path to the cubin file (compiled with nvcc, with -cubin). If left empty, the same path as executable and the name cubin-<executable> will be assumed."
    echo "  -a | --args : Arguments for running the binary. e.g. --args=\"64 2 2 temp_64 power_64 output_64.txt\""
    echo "  --sm_count : Can be used to specify the number of streaming multiprocessors of the current GPU, as this will be used in calculations (default: 16)"
    echo "  -j | --json : Save a JSON-formatted version of the output (Needed for the use of GPUscout-GUI)"
    echo "  --kernels : Comma-separated kernel patterns for NCU collection and end-to-end kernel filtering in final analysis output."
    echo "              If omitted, kernels are auto-discovered from generated SASS (cubin-scoped)."
    echo "  --analysis : Comma-separated analyses to run. e.g. --analysis=\"warp_divergence,use_shared\""
    echo "              If omitted, all analyses are enabled."
    echo "  --nsys-hotspot-kernels [num] : Run Nsight Systems, parse hotspot kernels, and use top kernels for profiling."
    echo "                                 Default num is 10 when not specified. Cannot be used with --kernels."
    exit 1
}

raw_args=("$@")
normalized_args=()
pre_nsys_hotspot_kernels_count=""
i=0
while [ "${i}" -lt "${#raw_args[@]}" ]; do
    arg="${raw_args[$i]}"
    case "${arg}" in
        --)
            normalized_args+=("${arg}")
            i=$((i + 1))
            while [ "${i}" -lt "${#raw_args[@]}" ]; do
                normalized_args+=("${raw_args[$i]}")
                i=$((i + 1))
            done
            ;;
        --nsys-hotspot-kernels)
            next_idx=$((i + 1))
            next_arg=""
            if [ "${next_idx}" -lt "${#raw_args[@]}" ]; then
                next_arg="${raw_args[$next_idx]}"
            fi
            if [ -n "${next_arg}" ] && [[ "${next_arg}" != -* ]]; then
                pre_nsys_hotspot_kernels_count="${next_arg}"
                i=$((i + 2))
            else
                pre_nsys_hotspot_kernels_count="10"
                i=$((i + 1))
            fi
            ;;
        *)
            normalized_args+=("${arg}")
            i=$((i + 1))
            ;;
    esac
done

# Parse command-line options
options=$(getopt -o hve:c:a:j -l help,dry_run,verbose,executable:,cubin:,args:,sm_count:,json,kernels:,analysis: -- "${normalized_args[@]}")

if [ $? -ne 0 ]; then
    echo "Error: Invalid option."
    usage
fi

eval set -- "$options"

dry_run=false
verbose=false
json=false
executable=""
cubin=""
args=""
sms=16
kernels_arg=""
analysis_arg=""
nsys_hotspot_kernels_count="${pre_nsys_hotspot_kernels_count}"
while true; do
    case "$1" in
        -h | --help)
            usage
            ;;
        -e | --executable)
            executable="$2"
            shift 2
            ;;
        -c | --cubin)
            cubin="$2"
            shift 2
            ;;
        -a | --args)
            args="$2"
            shift 2
            ;;
        --dry_run)
            dry_run=true
            shift
            ;;
        -v | --verbose)
            verbose=true
            shift
            ;;
         -j | --json)
            json=true
            shift
            ;;
         --sm_count)
            sms="$2"
            shift 2
            ;;
        --kernels)
            kernels_arg="$2"
            shift 2
            ;;
        --analysis)
            analysis_arg="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Internal error during parsing."
            exit 1
            ;;
    esac
done

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

normalize_csv_list() {
    local raw="$1"
    local normalized
    normalized=$(printf '%s' "${raw}" | sed -E 's/[[:space:]]*,[[:space:]]*/,/g')
    trim_whitespace "${normalized}"
}

validate_csv_list_syntax() {
    local raw="$1"
    local option_name="$2"
    local normalized
    normalized="$(normalize_csv_list "${raw}")"

    if [ -z "${normalized}" ] || [[ "${normalized}" == ,* ]] || [[ "${normalized}" == *, ]] || [[ "${normalized}" == *",,"* ]]; then
        echo "ERROR: Malformed --${option_name} list: \"${raw}\""
        echo "Expected comma-separated non-empty values, e.g. a,b,c"
        exit 1
    fi
}

is_valid_analysis_name() {
    local candidate="$1"
    local allowed
    for allowed in \
        register_spilling \
        use_restrict \
        vectorization \
        global_atomics \
        warp_divergence \
        use_texture \
        use_shared \
        datatype_conversion \
        deadlock_detection
    do
        if [ "${candidate}" = "${allowed}" ]; then
            return 0
        fi
    done
    return 1
}

validate_analysis_values() {
    local raw="$1"
    local normalized token trimmed
    local token_list=()
    local invalid=()

    normalized="$(normalize_csv_list "${raw}")"
    IFS=',' read -r -a token_list <<< "${normalized}"

    for token in "${token_list[@]}"; do
        trimmed="$(trim_whitespace "${token}")"
        if ! is_valid_analysis_name "${trimmed}"; then
            invalid+=("${trimmed}")
        fi
    done

    if [ "${#invalid[@]}" -gt 0 ]; then
        local IFS=,
        echo "ERROR: Invalid analysis name(s): ${invalid[*]}"
        echo "Valid values: register_spilling,use_restrict,vectorization,global_atomics,warp_divergence,use_texture,use_shared,datatype_conversion,deadlock_detection"
        exit 1
    fi
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

extract_top_kernel_names_from_csv() {
    local csv_file="$1"
    local top_n="$2"

    python3 - "${csv_file}" "${top_n}" <<'PY'
import csv
import sys

csv_file = sys.argv[1]
top_n = int(sys.argv[2])

with open(csv_file, "r", newline="", encoding="utf-8-sig") as handle:
    reader = csv.reader(handle)
    header = next(reader, None)
    if not header:
        raise SystemExit(1)
    stripped = [h.strip() for h in header]
    if "Name" not in stripped:
        raise SystemExit(2)
    name_idx = stripped.index("Name")
    emitted = 0
    for row in reader:
        if len(row) <= name_idx:
            continue
        name = row[name_idx].strip()
        if not name:
            continue
        print(name)
        emitted += 1
        if emitted >= top_n:
            break
    if emitted == 0:
        raise SystemExit(3)
PY
}

discover_nsys_hotspot_kernels() {
    local top_n="$1"
    local profile_prefix="${gpuscout_tmp_dir}/nsys-profile-${run_prefix}"
    local stats_prefix="${gpuscout_tmp_dir}/nsys-stats-${run_prefix}"
    local rep_file=""
    local stats_csv=""
    local collapsed_csv=""
    local parser_script="${gpuscout_dir}/nsys_report_to_hotspot_kernels.py"
    local hotspot_names=""
    local kernel
    local hotspot_kernels=()

    if ! command -v nsys >/dev/null 2>&1; then
        echo "ERROR: --nsys-hotspot-kernels requires 'nsys' in PATH."
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: --nsys-hotspot-kernels requires 'python3' in PATH."
        exit 1
    fi
    if [ ! -f "${parser_script}" ]; then
        echo "ERROR: Parser script not found: ${parser_script}"
        exit 1
    fi

    rm -f "${profile_prefix}".nsys-rep "${profile_prefix}".qdrep "${profile_prefix}".sqlite
    rm -f "${stats_prefix}"*.csv

    echo "Running Nsight Systems to auto-detect hotspot kernels (top ${top_n}) . . ."
    local start_nsys_profile end_nsys_profile nsys_profile_time
    start_nsys_profile="$(python3 -c 'import time; print(time.time())')"
    nsys profile --trace cuda --force-overwrite true --output "${profile_prefix}" ${executable} ${args}
    end_nsys_profile="$(python3 -c 'import time; print(time.time())')"
    nsys_profile_time=$(awk "BEGIN {print ${end_nsys_profile} - ${start_nsys_profile}}")
    echo "Nsight Systems profile time: ${nsys_profile_time}s"

    if [ -f "${profile_prefix}.nsys-rep" ]; then
        rep_file="${profile_prefix}.nsys-rep"
    elif [ -f "${profile_prefix}.qdrep" ]; then
        rep_file="${profile_prefix}.qdrep"
    else
        echo "ERROR: Nsight Systems did not produce a report file."
        exit 1
    fi

    local start_nsys_stats end_nsys_stats nsys_stats_time
    start_nsys_stats="$(python3 -c 'import time; print(time.time())')"
    if ! nsys stats --report cuda_gpu_kern_sum --output "${stats_prefix}" --format csv "${rep_file}"; then
        echo "ERROR: Failed to generate Nsight Systems kernel CSV report (cuda_gpu_kern_sum)."
        exit 1
    fi
    end_nsys_stats="$(python3 -c 'import time; print(time.time())')"
    nsys_stats_time=$(awk "BEGIN {print ${end_nsys_stats} - ${start_nsys_stats}}")
    echo "Nsight Systems stats time: ${nsys_stats_time}s"

    stats_csv="$(find "${gpuscout_tmp_dir}" -maxdepth 1 -type f -name "$(basename "${stats_prefix}")*.csv" | head -n 1)"
    if [ -z "${stats_csv}" ] || [ ! -f "${stats_csv}" ]; then
        echo "ERROR: Nsight Systems CSV report not found under ${gpuscout_tmp_dir}"
        exit 1
    fi

    collapsed_csv="$(python3 "${parser_script}" "${stats_csv}" | tail -n 1)"
    if [ -z "${collapsed_csv}" ] || [ ! -f "${collapsed_csv}" ]; then
        echo "ERROR: Failed to build collapsed hotspot CSV with ${parser_script}"
        exit 1
    fi

    hotspot_names="$(extract_top_kernel_names_from_csv "${collapsed_csv}" "${top_n}")"
    if [ -z "${hotspot_names}" ]; then
        echo "ERROR: No hotspot kernels found in ${collapsed_csv}"
        exit 1
    fi

    while IFS= read -r kernel; do
        kernel="$(trim_whitespace "${kernel}")"
        if [ -n "${kernel}" ]; then
            hotspot_kernels+=("${kernel}")
        fi
    done <<< "${hotspot_names}"

    if [ "${#hotspot_kernels[@]}" -eq 0 ]; then
        echo "ERROR: No valid hotspot kernel names extracted from ${collapsed_csv}"
        exit 1
    fi

    local IFS=,
    kernels_arg="${hotspot_kernels[*]}"
    echo "Nsight hotspot kernels selected: ${kernels_arg}"
}

if [ -n "${kernels_arg}" ]; then
    validate_csv_list_syntax "${kernels_arg}" "kernels"
fi
if [ -n "${analysis_arg}" ]; then
    validate_csv_list_syntax "${analysis_arg}" "analysis"
    validate_analysis_values "${analysis_arg}"
fi
if [ -n "${nsys_hotspot_kernels_count}" ]; then
    if ! is_positive_integer "${nsys_hotspot_kernels_count}"; then
        echo "ERROR: --nsys-hotspot-kernels expects a positive integer, got: ${nsys_hotspot_kernels_count}"
        exit 1
    fi
fi
if [ -n "${kernels_arg}" ] && [ -n "${nsys_hotspot_kernels_count}" ]; then
    echo "ERROR: --kernels cannot be used together with --nsys-hotspot-kernels."
    exit 1
fi

#check the params
if [ -z "$executable" ]; then
    echo "No executable specified (-e ..)"
    usage
fi
executable_filename=$(basename "$executable")
executable_dir="$( cd "$( dirname "$executable" )" && pwd )"
executable="$executable_dir/$executable_filename"
run_prefix=$executable_filename
if [ ! -f "$executable" ]; then
    echo "Executable not found at: $executable"
    exit 1
fi

if [ -z "$cubin" ]; then
    cubin_filename="cubin-$executable_filename"
    cubin_dir=$executable_dir
else
    cubin_filename=$(basename "$cubin")
    cubin_dir="$( cd "$( dirname "$cubin" )" && pwd )"
    
fi
cubin="$cubin_dir/$cubin_filename"
if [ ! -f "$cubin" ]; then
    echo "Cubin file not found at: $cubin"
    exit 1
fi

gpuscout_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
gpuscout_tmp_dir="${gpuscout_dir}/tmp-gpuscout"
gpuscout_output_dir="${gpuscout_tmp_dir}/output"
# Save metrics in a seperate directory
echo "======================================================================================================"
echo "==== Creating GPUscout TMP directory for storing metrics: ${gpuscout_tmp_dir}"
mkdir -p ${gpuscout_tmp_dir}

if [ "$json" = true ]; then
    mkdir -p ${gpuscout_output_dir}
fi

if [ -n "${nsys_hotspot_kernels_count}" ]; then
    discover_nsys_hotspot_kernels "${nsys_hotspot_kernels_count}"
fi

# Note: when you compile the code with nvcc, create 2 executables
# 1. without -cubin flag: <executable name>
# 2. with -cubin flag: prefix the name of the executable with cubin-<executable name>

echo "==== Executable: $executable"
echo "==== Cubin:      $cubin"
echo "==== Arguments for the executable file: \"$args\""
echo "==== Dry-run: $dry_run"
echo "==== Verbose: $verbose"
echo "==== JSON Output: $json"
echo "==== Kernels Filter: ${kernels_arg:-<not set: auto-select kernels from generated SASS (cubin-scoped)>}"
echo "==== Analyses: ${analysis_arg:-<not set: all analyses>}"
echo "==== Nsight Hotspot Kernels: ${nsys_hotspot_kernels_count:-<disabled>}"
echo "======================================================================================================"


echo "Clearing previous files . . . . . . . . . . . . . . . . . . . . "
# DO NOT REMOVE sampling_utilities directory !!!!!!!
rm -rf hpctoolkit-*-measurements 2>/dev/null
rm -rf hpctoolkit-*-database 2>/dev/null
rm -rf metrics 2>/dev/null
rm nvdisasm-hpctoolkit-* 2>/dev/null
rm nvdisasm-executable-* 2>/dev/null
rm nvdisasm-registers-hpctoolkit-* 2>/dev/null
rm nvdisasm-registers-executable-* 2>/dev/null
rm parser_sass_datatype_conversion 2>/dev/null
rm parser_ptx 2>/dev/null
rm pcsampling_*.txt 2>/dev/null
rm parser_metrics 2>/dev/null
rm parser_sass_restrict 2>/dev/null
rm parser_sass_vectorized 2>/dev/null
rm parser_sass_divergence 2>/dev/null
rm parser_sass_register_spilling 2>/dev/null
rm parser_pcsampling 2>/dev/null
rm parser_sass_deadlock_detection 2>/dev/null
rm parser_sass_use_texture 2>/dev/null
rm parser_sass_use_shared 2>/dev/null
rm merge_analysis_register_spilling 2>/dev/null
rm merge_analysis_use_restrict 2>/dev/null
rm merge_analysis_vectorization 2>/dev/null
rm merge_analysis_global_atomics 2>/dev/null
rm merge_analysis_warp_divergence 2>/dev/null
rm merge_analysis_use_texture 2>/dev/null
rm merge_analysis_use_shared 2>/dev/null
rm merge_analysis_datatype_conversion 2>/dev/null
rm merge_analysis_deadlock_detection 2>/dev/null

echo "Setting up profiling . . . . . . . . . . . . . . . "
# Remove and Create build directory
#rm -rf $PWD/build/ && mkdir -p $PWD/build/

# ------------------------ WITH HPCTOOLKIT ------------------------
# # Save your executable in a directory named "executable"
# cd $PWD/build/
# echo "Loading spack . . . . . . . . . . . . . . . . . . . . "
# spack load hpctoolkit@2022.10.01
# # for ice1
# # module unload hpctoolkit
# # module load hpctoolkit/2022.01.15/gcc-11.2.0-module-y42vztd

# echo "Start profiling with hpctoolkit to generate the gpubin file . . . . . . . . . . . . . . . "
# hpcrun -e REALTIME -e gpu=nvidia,pc -t ./../executable/$file_name $args
# hpcstruct --gpucfg yes hpctoolkit-$file_name-measurements/
# hpcprof hpctoolkit-$file_name-measurements/

# # Disassemble to get the SASS and ptx and output it to txt file
# echo "SASS from hpctoolkit generated gpubin . . . . . . . . . . . . . . . "
# # remove the inlined information from nvdisasm
# # gpubins-used UNPREDICTABLE!
# # nvdisasm -g -c hpctoolkit-$file_name-measurements/gpubins-used/*.gpubin > nvdisasm-hpctoolkit-$file_name-sass.txt
# # for ice1
# nvdisasm -g -c hpctoolkit-$file_name-measurements/gpubins/*.gpubin > nvdisasm-hpctoolkit-$file_name-sass.txt

# echo "SASS directly from executable . . . . . . . . . . . . . . . "
# nvdisasm -g -c ./../executable/cubin-$file_name > nvdisasm-executable-$file_name-sass.txt

# echo "ptx directly from executable . . . . . . . . . . . . . . . "
# cuobjdump -ptx ./../executable/$file_name > nvdisasm-executable-$file_name-ptx.txt

# echo "SASS with live register info from hpctoolkit . . . . . . . . . . . . . . . "
# # nvdisasm -g -c -lrm=count hpctoolkit-$file_name-measurements/gpubins-used/*.gpubin > nvdisasm-registers-hpctoolkit-$file_name-sass.txt
# nvdisasm -g -c -lrm=count hpctoolkit-$file_name-measurements/gpubins/*.gpubin > nvdisasm-registers-hpctoolkit-$file_name-sass.txt

# echo "SASS with live register info from executable . . . . . . . . . . . . . . . "
# nvdisasm -g -c -lrm=count ./../executable/cubin-$file_name > nvdisasm-registers-executable-$file_name-sass.txt

# cd ..

# ------------------------ WITHOUT HPCTOOLKIT ------------------------
# Still using the name same as before (with hpctoolkit), just for ease
# Hence we are running the same commands below twice, once t generate the name with -hpctoolkit- and once to generate the name with -executable-

cd ${gpuscout_dir}
echo -e "Generating binaries . . . . . . . . . . . . . . . . . . . ."
start_static=$(date +%s.%N)
nvdisasm -g -c ${cubin} > ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${run_prefix}-sass.txt #TODO this line necessary?
nvdisasm -g -c ${cubin} > ${gpuscout_tmp_dir}/nvdisasm-executable-${run_prefix}-sass.txt
cuobjdump -ptx ${executable} > ${gpuscout_tmp_dir}/nvdisasm-executable-${run_prefix}-ptx.txt
nvdisasm -g -c -lrm=count ${cubin} > ${gpuscout_tmp_dir}/nvdisasm-registers-hpctoolkit-${run_prefix}-sass.txt #TODO this line necessary?
nvdisasm -g -c -lrm=count ${cubin} > ${gpuscout_tmp_dir}/nvdisasm-registers-executable-${run_prefix}-sass.txt
end_static=$(date +%s.%N)
static_time=$(awk "BEGIN {print $end_static - $start_static}")


# Run the generate_sampling_stalls script inside the sampling_utilities directory
if [ "$dry_run" = false ]; then
    echo "Getting warp stall reasons . . . . . . . . . . . . . . . "
    start_pcsampling=$(date +%s.%N)
    source ${gpuscout_dir}/sampling_utilities/generate_sampling_stalls.sh
    cp ${gpuscout_dir}/sampling_utilities/sampling_utility/pcsampling_${run_prefix}.txt ${gpuscout_tmp_dir}/pcsampling_${run_prefix}.txt
    end_pcsampling=$(date +%s.%N)
    pcsampling_time=$(awk "BEGIN {print $end_pcsampling - $start_pcsampling}")
fi

# Get the measurements and analysis from the measurements script
echo "Measurements and Analysis . . . . . . . . . . . . . . . (${gpuscout_dir}/analysis/measurements.sh)"
source ${gpuscout_dir}/analysis/measurements.sh

# Exit
echo -e "Profiling complete! Starting cleanup . . . . . . . . . . . . . . . . . . . ."

rm -rf ${gpuscout_output_dir}

# Remove the PC sampling files generate before release/production, else keep them for debug
# rm $PWD/sampling_utilities/sampling_continuous/*_pcsampling_*.dat
# rm $PWD/sampling_utilities/sampling_utility/pcsampling_$file_name.txt

exit 0
