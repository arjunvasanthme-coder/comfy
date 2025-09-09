LOGDIR="/var/log/portal"
STATUSDIR="${LOGDIR}/prov-status"
mkdir -p "$LOGDIR" "$STATUSDIR"

pids=()
names=()

# VAE
(
  get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"; ec=$?
  echo "$ec" > "${STATUSDIR}/dl_vae.exit"
) > "${LOGDIR}/dl_vae.log" 2>&1 &
pids+=("$!"); names+=("dl_vae")

# TEXT ENCODERS
(
  get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"; ec=$?
  echo "$ec" > "${STATUSDIR}/dl_text_enc.exit"
) > "${LOGDIR}/dl_text_enc.log" 2>&1 &
pids+=("$!"); names+=("dl_text_enc")

# DIFFUSION
(
  get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"; ec=$?
  echo "$ec" > "${STATUSDIR}/dl_diff.exit"
) > "${LOGDIR}/dl_diff.log" 2>&1 &
pids+=("$!"); names+=("dl_diff")

# PIP (venv already activated at top of script)
(
  pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"; ec=$?
  echo "$ec" > "${STATUSDIR}/pip_reqs.exit"
) > "${LOGDIR}/pip_reqs.log" 2>&1 &
pids+=("$!"); names+=("pip_reqs")

# Wait (don’t fail script)
for pid in "${pids[@]}"; do wait "$pid" || true; done

# Summary
echo "----- Provisioning task summary -----"
for n in "${names[@]}"; do
  ec="$(cat "${STATUSDIR}/${n}.exit" 2>/dev/null || echo 1)"
  if [[ "$ec" -eq 0 ]]; then
    echo "[OK]   ${n}"
  else
    echo "[FAIL] ${n} (exit ${ec}) -> see ${LOGDIR}/${n}.log"
  fi
done
