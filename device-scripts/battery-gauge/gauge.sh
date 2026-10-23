#!/bin/sh
# MU5120 软件电量计：由 systemd timer 每 1 秒执行一次
# 插电满 lcm.conf 设定的分钟数（默认 30）后自动切换 customer_mode=2（单次长充电模式）
# 仅计算并输出真实 SOC（不写内核节点：屏幕走 ZTE 自研估算层，写了也看不到）

BASE=/cache/battery-gauge
RUN=/run/battery-gauge
CHECKPOINT=$BASE/checkpoint
STATE=$RUN/state.json
BAT=/sys/class/power_supply/battery
BAT_ZTE=/sys/class/power_supply/battery_zte
CAP_MAH=9800
R_MOHM=25
CHECKPOINT_SEC=60

mkdir -p "$RUN" || exit 1
now=$(date +%s)

read_number() {
    value=$(cat "$1" 2>/dev/null)
    case "$value" in
        ''|*[!0-9-]*) echo "$2" ;;
        *) echo "$value" ;;
    esac
}

ocv_init_permille() {
    awk -v v="$1" 'BEGIN {
        split("3400 3500 3600 3700 3750 3800 3850 3900 3950 4000 4050 4100 4150 4200 4250 4300 4350 4400 4450", x, " ");
        split("0 20 45 75 100 130 170 210 250 290 330 380 440 510 590 680 780 900 1000", y, " ");
        if (v <= x[1]) { print 0; exit }
        if (v >= x[19]) { print 1000; exit }
        for (j = 1; j < 19; j++) if (v >= x[j] && v < x[j+1]) {
            printf "%d", y[j] + (v-x[j]) * (y[j+1]-y[j]) / (x[j+1]-x[j]);
            exit
        }
    }'
}

v=$(read_number "$BAT/voltage_now" 4000000)
i=$(read_number "$BAT/current_now" 0)
t=$(read_number "$BAT/temp" 0)
st=$(cat "$BAT/status" 2>/dev/null || echo Unknown)
mv=$((v / 1000))
ma=$((i / 1000))

soc=
ts0=
if [ -r "$RUN/soc" ] && [ -r "$RUN/ts" ]; then
    soc=$(cat "$RUN/soc" 2>/dev/null)
    ts0=$(cat "$RUN/ts" 2>/dev/null)
elif [ -r "$CHECKPOINT" ]; then
    read -r soc ts0 < "$CHECKPOINT"
elif [ -r "$BASE/soc" ]; then
    soc=$(cat "$BASE/soc" 2>/dev/null)
    ts0=$(cat "$BASE/ts" 2>/dev/null)
fi

case "$ts0" in ''|*[!0-9]*) ts0=$now ;; esac
if [ -z "$soc" ]; then
    ocvmv=$((mv - ma * R_MOHM / 1000))
    [ "$ocvmv" -lt 3300 ] && ocvmv=3300
    [ "$ocvmv" -gt 4450 ] && ocvmv=4450
    soc=$(ocv_init_permille "$ocvmv" | awk '{ printf "%.4f", $1 / 10 }')
    ts0=$now
fi

dt=$((now - ts0))
[ "$dt" -lt 0 ] && dt=0
[ "$dt" -gt 120 ] && dt=120

soc=$(awk -v soc="$soc" -v i="$i" -v dt="$dt" -v cap="$CAP_MAH" 'BEGIN {
    value = soc + i * dt / 3600.0 / (cap * 1000) * 100;
    if (value < 0) value = 0;
    if (value > 100) value = 100;
    printf "%.4f", value
}')

if [ "$st" = "Charging" ] || [ "$st" = "Full" ]; then
    if [ "$mv" -ge 4350 ] && [ "$ma" -lt 300 ]; then soc=100.0000; fi
    [ "$st" = "Full" ] && soc=100.0000
fi
if [ "$st" = "Discharging" ] && [ "$mv" -le 3450 ]; then
    soc=1.5000
fi

# === 插电满 N 分钟后切到 customer_mode=2（CUSTOMER_SINGLE_LONG_CHARGING_MODE） ===
# 目的：不等原厂 16 小时（960 分钟）的长充电周期，自己提前进入长充电/直供策略。
# 阈值来自 /cache/battery-gauge/lcm.conf（纯数字，单位分钟，默认 30）。
# 临时停用：touch /cache/battery-gauge/no-lcm
# 说明：驱动只允许 customer_mode 升级（2 不可降回 1），重启后恢复默认。
lcm_min=30
if [ -r "$BASE/lcm.conf" ]; then
    v=$(cat "$BASE/lcm.conf" 2>/dev/null | tr -dc '0-9')
    [ -n "$v" ] && lcm_min=$v
fi

online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
case "$online" in 1) ;; *) online=0 ;; esac

PLUGF=$RUN/plug-start
LCMF=$RUN/lcm-applied
plug_min=0
lcm_state=0          # 0=未插电 1=计时中 2=已切换
customer_mode=$(cat "$BAT_ZTE/customer_mode" 2>/dev/null)
case "$customer_mode" in ''|*[!0-9]*) customer_mode=-1 ;; esac

if [ "$online" = 1 ]; then
    plug_start=$(cat "$PLUGF" 2>/dev/null)
    case "$plug_start" in
        ''|*[!0-9]*) plug_start=$now; printf '%s\n' "$now" > "$PLUGF" 2>/dev/null ;;
    esac
    plugged=$((now - plug_start))
    [ "$plugged" -lt 0 ] && plugged=0
    plug_min=$((plugged / 60))

    if [ -e "$LCMF" ]; then
        lcm_state=2
    elif [ -e "$BASE/no-lcm" ]; then
        lcm_state=1
    elif [ "$plugged" -ge $((lcm_min * 60)) ]; then
        printf '2\n' > "$BAT_ZTE/customer_mode" 2>/dev/null
        customer_mode=$(cat "$BAT_ZTE/customer_mode" 2>/dev/null)
        case "$customer_mode" in ''|*[!0-9]*) customer_mode=-1 ;; esac
        printf '%s switch_to_lcm plugged_min=%s mode=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$plug_min" "$customer_mode" >> "$BASE/lcm.log" 2>/dev/null
        printf '%s\n' "$now" > "$LCMF" 2>/dev/null
        lcm_state=2
    else
        lcm_state=1
    fi
else
    # 拔电：本次插电会话结束，重置计时（customer_mode 本身不会自动降级）
    rm -f "$PLUGF" "$LCMF" 2>/dev/null
    lcm_state=0
    plug_min=0
fi

# === 供电模式判定（供页面展示） ===
# 注意：充满后充电器"终止充电"仍会持续浮充维持，不能等同于厂商的直供电。
#   充电中   ：插电 + status=Charging + 电流≥50mA
#   直供电   ：插电 + 充电被显式关闭（status=Not Charging 或 restrict_chg=1）
#   浮充维持 ：插电 + status=Full，充电器仍在微流维持（并非直供）
#   电池供电 ：未插电
restrict_chg=$(cat /sys/class/qcom-battery/restrict_chg 2>/dev/null)
case "$restrict_chg" in ''|*[!0-9]*) restrict_chg=0 ;; esac

if [ "$online" = 1 ]; then
    if [ "$st" = "Charging" ] && [ "$ma" -ge 50 ]; then
        power_mode=charging; power_mode_cn="充电中"
    elif [ "$st" = "Not Charging" ] || [ "$restrict_chg" = 1 ]; then
        power_mode=direct;   power_mode_cn="直供电"
    else
        power_mode=float;    power_mode_cn="浮充维持"
    fi
else
    power_mode=battery;      power_mode_cn="电池供电"
fi

printf '%s\n' "$soc" > "$RUN/.soc.tmp" && mv "$RUN/.soc.tmp" "$RUN/soc"
printf '%s\n' "$now" > "$RUN/.ts.tmp" && mv "$RUN/.ts.tmp" "$RUN/ts"

checkpoint_ts=0
if [ -r "$CHECKPOINT" ]; then
    read -r _ checkpoint_ts < "$CHECKPOINT"
fi
case "$checkpoint_ts" in ''|*[!0-9]*) checkpoint_ts=0 ;; esac
if [ $((now - checkpoint_ts)) -ge "$CHECKPOINT_SEC" ] || [ $((now - checkpoint_ts)) -lt 0 ]; then
    printf '%s %s\n' "$soc" "$now" > "$BASE/.checkpoint.tmp" &&
        mv "$BASE/.checkpoint.tmp" "$CHECKPOINT"
fi

# === 电池生命周期数据记录（SOC 每变化 1% / 60 秒心跳 / 状态变化时写一条） ===
LOG_DIR=/cache/battery-log
LOG=$LOG_DIR/cycle.csv
LASTF=$RUN/last-rec
mkdir -p "$LOG_DIR" /run/backup 2>/dev/null
[ -s "$LOG" ] || echo "ts_iso,ts,soc,voltage_mv,current_ma,power_w,temp_c,status" > "$LOG"
last_soc=; last_ts=; last_st=
if [ -r "$LASTF" ]; then read last_soc last_ts last_st < "$LASTF"; fi
need=0
case "$last_ts" in ''|*[!0-9]*) need=1;; esac
if [ "$need" = 0 ]; then
    dd1=$(awk -v a="$soc" -v b="${last_soc:-0}" 'BEGIN{d=a-b; if(d<0)d=-d; printf "%d", (d>=1)?1:0}')
    [ "$dd1" = 1 ] && need=1
    [ $((now - last_ts)) -ge 60 ] && need=1
    [ "$st" != "$last_st" ] && need=1
fi
if [ "$need" = 1 ]; then
    awk -v ts="$(date '+%Y-%m-%d %H:%M:%S')" -v now="$now" -v soc="$soc" -v mv="$mv" -v ma="$ma" -v t="$t" -v st="$st" 'BEGIN{
        printf "%s,%s,%s,%s,%s,%.4f,%.1f,%s\n", ts, now, soc, mv, ma, mv*ma/1000000, t/10, st
    }' >> "$LOG"
    printf '%s %s %s\n' "$soc" "$now" "$st" > "$LASTF"
    cp "$LOG" /run/backup/battery-log.csv 2>/dev/null
fi

awk -v soc="$soc" -v mv="$mv" -v ma="$ma" -v t="$t" -v st="$st" -v cap="$CAP_MAH" -v now="$now" \
    -v lmin="$lcm_min" -v lstate="$lcm_state" -v pmin="$plug_min" -v cmode="$customer_mode" \
    -v pmode="$power_mode" -v pcn="$power_mode_cn" 'BEGIN {
    st_cn = (st=="Charging") ? "充电中" : (st=="Discharging") ? "放电中" : (st=="Full") ? "已充满" : (st=="Not Charging") ? "未充电" : "未知";
    power = mv * ma / 1000000.0;
    printf "{\n";
    printf "  \"soc\": %.2f,\n", soc;
    printf "  \"voltage_mv\": %d,\n", mv;
    printf "  \"current_ma\": %d,\n", ma;
    printf "  \"power_w\": %.4f,\n", power;
    printf "  \"temp_c\": %.1f,\n", t / 10.0;
    printf "  \"status\": \"%s\",\n", st;
    printf "  \"status_cn\": \"%s\",\n", st_cn;
    printf "  \"summary\": \"电量约%.2f%%，%s，当前功率约%.4fW\",\n", soc, st_cn, power;
    printf "  \"capacity_mah_nominal\": %d,\n", cap;
    printf "  \"kernel_locked_percent\": 50,\n";
    printf "  \"power_mode\": \"%s\",\n", pmode;
    printf "  \"power_mode_cn\": \"%s\",\n", pcn;
    printf "  \"plugged_min\": %d,\n", pmin;
    printf "  \"long_charge\": {\"threshold_min\": %d, \"state\": %d, \"customer_mode\": %d},\n", lmin, lstate, cmode;
    printf "  \"method\": \"coulomb+ocv-anchor\",\n";
    printf "  \"interval_s\": 1,\n";
    printf "  \"ts\": %d\n", now;
    printf "}\n";
}' > "$RUN/.state.tmp" && mv "$RUN/.state.tmp" "$STATE"
