#!/bin/sh
# MU5120 软件电量计：由 systemd timer 每 10 秒执行一次。

BASE=/cache/battery-gauge
RUN=/run/battery-gauge
CHECKPOINT=$BASE/checkpoint
STATE=$RUN/state.json
BAT=/sys/class/power_supply/battery
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

awk -v soc="$soc" -v mv="$mv" -v ma="$ma" -v t="$t" -v st="$st" -v cap="$CAP_MAH" -v now="$now" 'BEGIN {
    st_cn = (st=="Charging") ? "充电中" : (st=="Discharging") ? "放电中" : (st=="Full") ? "已充满" : (st=="Not Charging") ? "未充电" : "未知";
    power = mv * ma / 1000000.0;
    printf "{\n";
    printf "  \"soc\": %.2f,\n", soc;
    printf "  \"voltage_mv\": %d,\n", mv;
    printf "  \"current_ma\": %d,\n", ma;
    printf "  \"power_w\": %.1f,\n", power;
    printf "  \"temp_c\": %.1f,\n", t / 10.0;
    printf "  \"status\": \"%s\",\n", st;
    printf "  \"status_cn\": \"%s\",\n", st_cn;
    printf "  \"summary\": \"电量约%.0f%%，%s，当前功率约%.1fW\",\n", soc, st_cn, power;
    printf "  \"capacity_mah_nominal\": %d,\n", cap;
    printf "  \"kernel_locked_percent\": 50,\n";
    printf "  \"method\": \"coulomb+ocv-anchor\",\n";
    printf "  \"interval_s\": 10,\n";
    printf "  \"ts\": %d\n", now;
    printf "}\n";
}' > "$RUN/.state.tmp" && mv "$RUN/.state.tmp" "$STATE"
