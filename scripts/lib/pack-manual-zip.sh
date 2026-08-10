#!/usr/bin/env bash
# 为 deploy_method=manual 的域名打 ZIP 包，放到 /data/packs/，供控制台手传。

pack_manual_zips() {
  local pack_root="${PACK_DIR:-/data/packs}"
  local cert_root="${CERT_DIR:-/data/certs}"
  local config="${DOMAINS_CONFIG:-/config/domains.yml}"
  mkdir -p "$pack_root"

  if [[ ! -f "$config" ]]; then
    log_warn "无 domains 配置，跳过手动 ZIP 打包"
    return 0
  fi

  local packed=0
  local domains
  domains=$(yq eval '.domains[].domain' "$config" 2>/dev/null || true)

  while IFS= read -r parent; do
    [[ -z "$parent" ]] && continue
    local subs
    subs=$(yq eval ".domains[] | select(.domain == \"$parent\") | .subdomains[]?" "$config" -o=json 2>/dev/null || true)

    # 逐条读子域名
    local sub_domains
    sub_domains=$(yq eval ".domains[] | select(.domain == \"$parent\") | .subdomains[] | select(.deploy_method == \"manual\") | .domain" "$config" 2>/dev/null || true)

    while IFS= read -r sub; do
      [[ -z "$sub" || "$sub" == "null" ]] && continue

      local cert_dir=""
      for cand in \
        "${cert_root}/${parent}" \
        "${cert_root}/${parent}_ecc" \
        "${cert_root}/*.${parent}" \
        "${cert_root}/*.${parent}_ecc"
      do
        # 通配展开
        for d in $cand; do
          if [[ -d "$d" && -f "$d/fullchain.cer" ]]; then
            cert_dir="$d"
            break 2
          fi
        done
      done

      if [[ -z "$cert_dir" ]]; then
        log_warn "手动域 $sub 无可用证书目录（父域 $parent），跳过打包"
        continue
      fi

      local stamp out
      stamp=$(date +%Y%m%d)
      out="${pack_root}/${sub}_${stamp}.zip"
      if command -v zip >/dev/null 2>&1; then
        (cd "$cert_dir" && zip -qr "$out" .)
      else
        # busybox/alpine 可能无 zip，用 tar.gz 回退
        out="${pack_root}/${sub}_${stamp}.tar.gz"
        tar -czf "$out" -C "$cert_dir" .
      fi
      log_info "已打包手动部署证书: $sub → $out"
      packed=$((packed + 1))

      # 通知（若 notify 可用）
      if declare -F send_notification >/dev/null 2>&1; then
        send_notification "info" "CertHub manual pack ready" "Domain: $sub\nPack: $out" 2>/dev/null || true
      fi
    done <<< "$sub_domains"
  done <<< "$domains"

  if (( packed == 0 )); then
    log_info "本次无手动域名需要打包"
  else
    log_info "手动 ZIP 打包完成：${packed} 个"
  fi
  return 0
}
