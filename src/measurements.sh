#!/bin/bash


#@(#) This is the measurements script that collects the Nsight Compute metrics and executes the SASS analysis code

echo "======================================================================================================"

valid_analyses=(
    register_spilling
    use_restrict
    vectorization
    global_atomics
    warp_divergence
    use_texture
    use_shared
    datatype_conversion
    deadlock_detection
)

trim_whitespace () {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# Parse a comma-separated list, validate list syntax, trim tokens, and deduplicate.
parse_csv_list () {
    local raw="$1"
    local option_name="$2"
    local normalized token trimmed
    local token_list=()

    parsed_csv_list=()

    normalized=$(printf '%s' "${raw}" | sed -E 's/[[:space:]]*,[[:space:]]*/,/g')
    normalized="$(trim_whitespace "${normalized}")"

    if [ -z "${normalized}" ] || [[ "${normalized}" == ,* ]] || [[ "${normalized}" == *, ]] || [[ "${normalized}" == *",,"* ]]; then
        echo "ERROR: Malformed --${option_name} list: \"${raw}\""
        echo "Expected comma-separated non-empty values, e.g. a,b,c"
        exit 1
    fi

    IFS=',' read -r -a token_list <<< "${normalized}"

    for token in "${token_list[@]}"; do
        trimmed="$(trim_whitespace "${token}")"
        if [ -z "${trimmed}" ]; then
            echo "ERROR: Empty token found in --${option_name} list: \"${raw}\""
            exit 1
        fi
        if ! array_contains "${trimmed}" "${parsed_csv_list[@]}"; then
            parsed_csv_list+=("${trimmed}")
        fi
    done
}

join_by_comma () {
    local IFS=','
    printf '%s' "$*"
}

is_valid_analysis () {
    local candidate="$1"
    local allowed
    for allowed in "${valid_analyses[@]}"; do
        if [ "${candidate}" = "${allowed}" ]; then
            return 0
        fi
    done
    return 1
}

array_contains () {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [ "${item}" = "${needle}" ]; then
            return 0
        fi
    done
    return 1
}

# Append only CSV data rows from a per-kernel NCU CSV.
append_ncu_csv_rows () {
    local src="$1"
    local dest="$2"

    # If src doesn't contain a CSV header, it likely has no data.
    if ! awk 'BEGIN{found=0} /^"ID"/{found=1} END{exit found?0:1}' "${src}"; then
        return 0
    fi

    if [ ! -f "${dest}" ]; then
        mv "${src}" "${dest}"
        return 0
    fi

    # Append only data rows (skip preamble and repeated header).
    awk 'BEGIN{in_csv=0} /^"ID"/{in_csv=1; next} in_csv==1 && /^"/{print}' "${src}" >> "${dest}"
    rm -f "${src}"
}

extract_kernels_from_generated_sass () {
    local sass_file="$1"
    local kernel

    extracted_cubin_kernels=()

    if [ ! -f "${sass_file}" ]; then
        echo "ERROR: Generated SASS file not found for kernel discovery: ${sass_file}"
        exit 1
    fi

    while IFS= read -r kernel; do
        kernel="$(trim_whitespace "${kernel}")"
        if [ -z "${kernel}" ]; then
            continue
        fi
        if ! array_contains "${kernel}" "${extracted_cubin_kernels[@]}"; then
            extracted_cubin_kernels+=("${kernel}")
        fi
    done < <(
        awk '
            /\.other[[:space:]]+/ && /STO_CUDA_ENTRY/ {
                line=$0
                sub(/^.*\.other[[:space:]]+/, "", line)
                sub(/,.*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line != "") print line
            }
        ' "${sass_file}"
    )

    if [ "${#extracted_cubin_kernels[@]}" -eq 0 ]; then
        while IFS= read -r kernel; do
            kernel="$(trim_whitespace "${kernel}")"
            if [ -z "${kernel}" ]; then
                continue
            fi
            if ! array_contains "${kernel}" "${extracted_cubin_kernels[@]}"; then
                extracted_cubin_kernels+=("${kernel}")
            fi
        done < <(
            awk '
                /\.section[[:space:]]+\.text\./ {
                    line=$0
                    sub(/^.*\.section[[:space:]]+\.text\./, "", line)
                    sub(/,.*/, "", line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                    if (line != "") print line
                }
            ' "${sass_file}"
        )
    fi

    if [ "${#extracted_cubin_kernels[@]}" -eq 0 ]; then
        echo "ERROR: No CUDA kernels were found in generated SASS: ${sass_file}"
        exit 1
    fi
}

kernels_selection_mode="user"
if [ -z "${kernels_arg:-}" ]; then
    extract_kernels_from_generated_sass "${gpuscout_tmp_dir}/nvdisasm-executable-${run_prefix}-sass.txt"
    top_kernels=("${extracted_cubin_kernels[@]}")
    kernels_selection_mode="auto_from_generated_sass"
else
    parse_csv_list "${kernels_arg}" "kernels"
    top_kernels=("${parsed_csv_list[@]}")
fi

if [ -z "${analysis_arg:-}" ]; then
    enabled_analyses=("${valid_analyses[@]}")
else
    parse_csv_list "${analysis_arg}" "analysis"
    enabled_analyses=("${parsed_csv_list[@]}")
fi

invalid_analyses=()
for analysis in "${enabled_analyses[@]}"; do
    if ! is_valid_analysis "${analysis}"; then
        invalid_analyses+=("${analysis}")
    fi
done

if [ "${#invalid_analyses[@]}" -gt 0 ]; then
    echo "ERROR: Invalid analysis name(s): $(join_by_comma "${invalid_analyses[@]}")"
    echo "Valid values: $(join_by_comma "${valid_analyses[@]}")"
    exit 1
fi

echo "Selected kernels for NCU collection: $(join_by_comma "${top_kernels[@]}")"
echo "Selected analyses: $(join_by_comma "${enabled_analyses[@]}")"
echo "Kernel selection mode: ${kernels_selection_mode}"

# Always apply end-to-end kernel filtering based on the effective kernel set.
kernel_filter_csv="$(join_by_comma "${top_kernels[@]}")"

# Build a comma-separated metric list for NCU (de-duplicated).
# If `json=true`, include metrics needed by JSON export as well.
_metrics_set=()
_add_metrics () {
    local m
    for m in "$@"; do
        if ! array_contains "$m" "${_metrics_set[@]}"; then
            _metrics_set+=("$m")
        fi
    done
}
_metrics_csv () {
    local IFS=,
    printf '%s' "${_metrics_set[*]}"
}

# Per-analysis metric requirements (must match parser_metrics.hpp names).
# Register spilling (includes load_data_memory_flow helper metrics)
_metrics_register_spilling=(
    smsp__warp_issue_stalled_long_scoreboard_per_warp_active.pct
    smsp__warp_issue_stalled_lg_throttle_per_warp_active.pct
    smsp__inst_executed_op_local_ld.sum
    smsp__inst_executed_op_local_st.sum
    l1tex__t_sector_hit_rate.pct
    lts__t_sectors_op_read.sum
    lts__t_sectors_op_write.sum
    lts__t_sectors_op_atom.sum
    lts__t_sectors_op_red.sum
    sm__sass_inst_executed_op_global_ld.sum
    l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum
    l1tex__t_sector_pipe_lsu_mem_global_op_ld_hit_rate.pct
    l1tex__t_sectors_pipe_lsu_mem_local_op_ld.sum
    l1tex__t_sector_pipe_lsu_mem_local_op_ld_hit_rate.pct
    lts__t_sector_op_read_hit_rate.pct
)
# __restrict__
_metrics_use_restrict=(
    smsp__warp_issue_stalled_imc_miss_per_warp_active.pct
)
# Vectorization
_metrics_vectorization=(
    smsp__warp_issue_stalled_long_scoreboard_per_warp_active.pct
    sm__warps_active.avg.pct_of_peak_sustained_active
)
# Global atomics (includes atomic_data_memory_flow helper metrics)
_metrics_global_atomics=(
    smsp__warp_issue_stalled_lg_throttle_per_warp_active.pct
    smsp__warp_issue_stalled_long_scoreboard_per_warp_active.pct
    smsp__warp_issue_stalled_mio_throttle_per_warp_active.pct
    l1tex__t_sectors_pipe_lsu_mem_global_op_red.sum
    l1tex__t_sectors_pipe_lsu_mem_global_op_atom.sum
    l1tex__t_sector_pipe_lsu_mem_global_op_red_hit_rate.pct
    l1tex__t_sector_pipe_lsu_mem_global_op_atom_hit_rate.pct
    lts__t_sector_op_red_hit_rate.pct
    lts__t_sector_op_atom_hit_rate.pct
    sm__sass_data_bytes_mem_shared_op_atom.sum
)
# Warp divergence
_metrics_warp_divergence=(
    sm__sass_branch_targets.avg
    sm__sass_branch_targets_threads_divergent.avg
)
# Texture (includes texture_data_memory_flow helper metrics)
_metrics_use_texture=(
    smsp__warp_issue_stalled_tex_throttle_per_warp_active.pct
    smsp__warp_issue_stalled_long_scoreboard_per_warp_active.pct
    sm__sass_inst_executed_op_texture.sum
    l1tex__t_sectors_pipe_tex_mem_texture.sum
    l1tex__t_sector_pipe_tex_mem_texture_op_tex_hit_rate.pct
    lts__t_sector_op_read_hit_rate.pct
)
# Shared (includes shared_data_memory_flow + shared_memory_bank_conflict helper metrics)
_metrics_use_shared=(
    smsp__warp_issue_stalled_long_scoreboard_per_warp_active.pct
    smsp__warp_issue_stalled_mio_throttle_per_warp_active.pct
    sm__sass_inst_executed_op_shared_ld.sum
    smsp__sass_average_data_bytes_per_wavefront_mem_shared_op_ld.pct
    l1tex__data_pipe_lsu_wavefronts_mem_shared_op_ld.sum
)
# Datatype conversion
_metrics_datatype_conversion=(
    smsp__warp_issue_stalled_tex_throttle_per_warp_active.pct
    smsp__warp_issue_stalled_mio_throttle_per_warp_active.pct
    smsp__warp_issue_stalled_short_scoreboard_per_warp_active.pct
)
# Deadlock detection does not use NCU metrics.

# Metrics needed by JSON export (save_to_json -> total_memory_flow + misc).
_metrics_json_export=(
            # total_memory_flow() inputs
            l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum
            l1tex__t_sector_pipe_lsu_mem_global_op_ld_hit_rate.pct
            l1tex__t_sectors_pipe_lsu_mem_global_op_st.sum
            l1tex__t_sector_pipe_lsu_mem_global_op_st_hit_rate.pct
            l1tex__t_sectors_pipe_lsu_mem_local_op_ld.sum
            l1tex__t_sector_pipe_lsu_mem_local_op_ld_hit_rate.pct
            l1tex__t_sectors_pipe_lsu_mem_local_op_st.sum
            l1tex__t_sector_pipe_lsu_mem_local_op_st_hit_rate.pct
            l1tex__t_sectors_pipe_tex_mem_texture.sum
            l1tex__t_sector_pipe_tex_mem_texture_op_tex_hit_rate.pct
            lts__t_sector_op_read_hit_rate.pct
            lts__t_sector_op_write_hit_rate.pct
            lts__t_sector_hit_rate.pct
            l1tex__t_sectors_pipe_lsu_mem_global_op_red.sum
            l1tex__t_sectors_pipe_lsu_mem_global_op_atom.sum
            l1tex__t_sector_pipe_lsu_mem_global_op_red_hit_rate.pct
            l1tex__t_sector_pipe_lsu_mem_global_op_atom_hit_rate.pct
            lts__t_sector_op_red_hit_rate.pct
            lts__t_sector_op_atom_hit_rate.pct
            l1tex__data_pipe_lsu_wavefronts_mem_shared_op_ld.sum
            sm__sass_inst_executed_op_shared_ld.sum
            sm__sass_inst_executed_op_shared_st.sum
            sm__sass_inst_executed_op_local_ld.sum
            sm__sass_inst_executed_op_local_st.sum
            sm__sass_inst_executed_op_global_ld.sum
            sm__sass_inst_executed_op_global_st.sum
            sm__sass_inst_executed_op_texture.sum
            smsp__sass_inst_executed.sum
            smsp__inst_executed_op_local_ld.sum
            smsp__inst_executed_op_local_st.sum
            l1tex__t_sector_hit_rate.pct
            lts__t_sectors_op_read.sum
            lts__t_sectors_op_write.sum
            lts__t_sectors_op_atom.sum
            lts__t_sectors_op_red.sum
            smsp__inst_executed_op_global_ld.sum
            memory_l2_theoretical_sectors_global
            memory_l2_theoretical_sectors_global_ideal
            memory_l1_wavefronts_shared
            memory_l1_wavefronts_shared_ideal

            # "misc" JSON serialization currently includes these
            sm__warps_active.avg.pct_of_peak_sustained_active
            smsp__warps_active.sum
            smsp__warp_issue_stalled_barrier_per_warp_active.pct
            smsp__warp_issue_stalled_membar_per_warp_active.pct
            smsp__warp_issue_stalled_short_scoreboard_per_warp_active.pct
            smsp__warp_issue_stalled_wait_per_warp_active.pct
            smsp__warp_issue_stalled_imc_miss_per_warp_active.pct
            smsp__warp_issue_stalled_long_scoreboard_per_warp_active.pct
            smsp__warp_issue_stalled_lg_throttle_per_warp_active.pct
            smsp__warp_issue_stalled_mio_throttle_per_warp_active.pct
            smsp__warp_issue_stalled_tex_throttle_per_warp_active.pct
        )

for analysis in "${enabled_analyses[@]}"; do
    case "$analysis" in
        register_spilling)   _add_metrics "${_metrics_register_spilling[@]}" ;;
        use_restrict)        _add_metrics "${_metrics_use_restrict[@]}" ;;
        vectorization)       _add_metrics "${_metrics_vectorization[@]}" ;;
        global_atomics)      _add_metrics "${_metrics_global_atomics[@]}" ;;
        warp_divergence)     _add_metrics "${_metrics_warp_divergence[@]}" ;;
        use_texture)         _add_metrics "${_metrics_use_texture[@]}" ;;
        use_shared)          _add_metrics "${_metrics_use_shared[@]}" ;;
        datatype_conversion) _add_metrics "${_metrics_datatype_conversion[@]}" ;;
        deadlock_detection)  : ;;
        *)
            echo "ERROR: Unknown analysis name in enabled_analyses: $analysis"
            exit 1
            ;;
    esac
done

if [ "$json" = true ]; then
    _add_metrics "${_metrics_json_export[@]}"
fi

metrics_csv="$(_metrics_csv)"
ncu_metrics_required=false
if [ -n "${metrics_csv}" ]; then
    ncu_metrics_required=true
fi

if [ "$dry_run" = false ]; then
    if [ "$ncu_metrics_required" = true ]; then
        echo "Collecting NCU metrics . . . . . . . . . . . . . . . "
        start_metrics=$(date +%s.%N)
        metrics_out="${run_prefix}_metrics_list"

        echo "NCU mode: one launch per selected kernel (skip=5)"
        ncu_kernel_base_args=()
        if [ "${kernels_selection_mode}" = "auto_from_generated_sass" ]; then
            ncu_kernel_base_args=(--kernel-name-base mangled)
        fi

        rm -f "${metrics_out}"

        for kernel in "${top_kernels[@]}"; do
            echo "Profiling NCU metrics for kernel pattern: ${kernel}"
            tmp_csv="$(mktemp)"

            ncu -f --csv --log-file "${tmp_csv}" --print-units base --print-kernel-base mangled \
                "${ncu_kernel_base_args[@]}" \
                --kernel-name "${kernel}" -s 5 --launch-count 1 \
                --metrics "${metrics_csv}" \
                ${executable} ${args}

            append_ncu_csv_rows "${tmp_csv}" "${metrics_out}"
        done

        if [ ! -f "${metrics_out}" ]; then
            echo "ERROR: NCU did not produce any CSV rows for the selected kernels."
            exit 1
        fi

        mv "${metrics_out}" "${gpuscout_tmp_dir}/${metrics_out}"
        end_metrics=$(date +%s.%N)
        metrics_time=$(awk "BEGIN {print $end_metrics - $start_metrics}")
    else
        echo "Skipping NCU metrics collection: selected analyses do not require NCU metrics."
        metrics_time=0
    fi
fi


cd ${gpuscout_dir}/analysis

echo "======================================================================================================"
start_analysis=$(date +%s.%N)

# Time a command (wall clock) and print duration.
# Usage: timed_run "<label>" <command> [args...]
timed_run () {
    local label="$1"
    shift
    local t0 t1 dt
    t0=$(date +%s.%N)
    "$@"
    t1=$(date +%s.%N)
    dt=$(awk "BEGIN {print $t1 - $t0}")
    echo "Time for ${label}: ${dt}s"
}

# Run only the analyses selected in `enabled_analyses` above.
for analysis in "${enabled_analyses[@]}"; do
    case "$analysis" in
        register_spilling)
            echo "======================================================================================================"
            echo "Combining above results for register spilling analysis . . . . . . . . . . . . . . . "
            timed_run "register spilling analysis" ./merge_analysis_register_spilling ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${gpuscout_tmp_dir}/nvdisasm-registers-executable-${executable_filename}-sass.txt ${json} ${gpuscout_output_dir} ${sms} "${kernel_filter_csv}"
            ;;
        use_restrict)
            echo "======================================================================================================"
            echo "Combining above results for using __restrict__ analysis . . . . . . . . . . . . . . . "
            timed_run "use __restrict__ analysis" ./merge_analysis_use_restrict ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${gpuscout_tmp_dir}/nvdisasm-registers-hpctoolkit-${executable_filename}-sass.txt ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        vectorization)
            echo "======================================================================================================"
            echo "Combining above results for vectorization analysis . . . . . . . . . . . . . . . "
            timed_run "vectorization analysis" ./merge_analysis_vectorization ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${gpuscout_tmp_dir}/nvdisasm-registers-hpctoolkit-${executable_filename}-sass.txt ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        global_atomics)
            echo "======================================================================================================"
            echo "Combining above results for global atomics analysis . . . . . . . . . . . . . . . "
            timed_run "global atomics analysis" ./merge_analysis_global_atomics ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        warp_divergence)
            echo "======================================================================================================"
            echo "Combining above results for warp divergence analysis . . . . . . . . . . . . . . . "
            timed_run "warp divergence analysis" ./merge_analysis_warp_divergence ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        use_texture)
            echo "======================================================================================================"
            echo "Combining above results for using texture memory analysis . . . . . . . . . . . . . . . "
            timed_run "use texture memory analysis" ./merge_analysis_use_texture ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        use_shared)
            echo "======================================================================================================"
            echo "Combining above results for using shared memory analysis . . . . . . . . . . . . . . . "
            timed_run "use shared memory analysis" ./merge_analysis_use_shared ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        datatype_conversion)
            echo "======================================================================================================"
            echo "Combining above results for datatype conversion analysis . . . . . . . . . . . . . . . "
            timed_run "datatype conversion analysis" ./merge_analysis_datatype_conversion ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        deadlock_detection)
            echo "======================================================================================================"
            echo "Combining above results for deadlock detection . . . . . . . . . . . . . . . "
            timed_run "deadlock detection analysis" ./merge_analysis_deadlock_detection ${gpuscout_tmp_dir}/nvdisasm-hpctoolkit-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${json} ${gpuscout_output_dir} "${kernel_filter_csv}"
            ;;
        *)
            echo "ERROR: Unknown analysis name in enabled_analyses (merge stage): $analysis"
            exit 1
            ;;
    esac
done

# Merge all individual JSON files

if [ "$json" = true ]; then

echo "======================================================================================================"
echo "Generating JSON output . . . . . . . . . . . . . . . "

./save_to_json ${gpuscout_output_dir} ${gpuscout_tmp_dir}/result-${run_prefix} ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-registers-executable-${executable_filename}-sass.txt ${gpuscout_tmp_dir}/nvdisasm-executable-${executable_filename}-ptx.txt ${gpuscout_tmp_dir}/pcsampling_${executable_filename}.txt ${gpuscout_tmp_dir}/${run_prefix}_metrics_list ${sms} "${kernel_filter_csv}"

fi

end_analysis=$(date +%s.%N)
analysis_time=$(awk "BEGIN {print $end_analysis - $start_analysis}")

echo "======================================================================================================"
echo "Time for Static Code Analysis: ${static_time}s"
if [ "$dry_run" = false ]; then
    echo "Time for PC Sampling:          ${pcsampling_time}s"
    echo "Time for Metrics Collection:   ${metrics_time}s"
fi
echo "Time for Merging Analysis:             ${analysis_time}s"
echo "======================================================================================================"

cd ..
