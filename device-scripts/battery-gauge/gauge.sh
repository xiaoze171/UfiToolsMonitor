#!/bin/sh
# battery-gauge: 软件电量计（针对 MU5120 固件电量锁死 50% 的替代方案）
# 原理：库仑积分（电流×时间/容量）+ 满充/空电锚点校准 + 电压兜底
# 开销：每 5 秒 4 次 sysfs 读 + 1 次 awk，CPU 占用 <0.1%
DIR=/cache/battery-gauge
SOCF=$DIR/soc
TSF=$DIR/ts
TMP=$DIR/state.tmp
OUT=$DIR/state.json
CAP_MAH=9800        # 标称容量（可按实测老化调整）
R_MOHM=25           # 估算内阻 mΩ（用于充电时还原 OCV）
BAT=/sys/class/power_supply/battery

# 无历史状态时：用 OCV 曲线初始化（4.45V 高压锂电，mV -> 千分比 SOC）
ocv_init_permille() {
awk -v v="$1" 'BEGIN{
  split("3400 3500 3600 3700 3750 3800 3850 3900 3950 4000 4050 4100 4150 4200 4250 4300 4350 4400 4450",x," ");
  split("0 20 45 75 100 130 170 210 250 290 330 380 440 510 590 680 780 900 1000",y," ");
  if(v<=x[1]){print 0;exit} if(v>=x[19]){print 1000;exit}
  for(j=1;j<19;j++) if(v>=x[j] && v<x[j+1]){
    printf "%d", y[j]+(v-x[j])*(y[j+1]-y[j])/(x[j+1]-x[j]); exit}
}'
}

# 开机首次运行：根据当前电流方向修正 OCV 估计
if [ ! -f "$SOCF" ]; then
  v=$(cat $BAT/voltage_now 2>/dev/null || echo 4000000)
  i=$(cat $BAT/current_now 2>/dev/null || echo 0)
  mv=$((v/1000)); ma=$((i/1000))
  # 充电时减去内阻压降，放电时加回（都在还原 OCV）
  ocvmv=$((mv - ma*R_MOHM/1000))
  [ $ocvmv -lt 3300 ] && ocvmv=3300
  [ $ocvmv -gt 4450 ] && ocvmv=4450
  soc=$(ocv_init_permille $ocvmv | awk '{printf "%.1f", $1/10}')  # 千分比 -> 百分比
  echo $soc > "$SOCF"
  date +%s > "$TSF"
fi

while :; do
  now=$(date +%s)
  ts0=$(cat "$TSF" 2>/dev/null || echo $now)
  dt=$((now - ts0))
  # 长时间休眠/时钟跳变时钳位，防止 SOC 突跳
  [ $dt -lt 0 ] && dt=0
  [ $dt -gt 120 ] && dt=120

  v=$(cat $BAT/voltage_now 2>/dev/null || echo 0)      # µV
  i=$(cat $BAT/current_now 2>/dev/null || echo 0)      # µA，充电为正
  t=$(cat $BAT/temp 2>/dev/null || echo 0)             # 0.1°C
  st=$(cat $BAT/status 2>/dev/null || echo Unknown)
  mv=$((v/1000)); ma=$((i/1000))

  soc=$(awk -v soc="$(cat $SOCF)" -v i="$i" -v dt="$dt" -v cap="$CAP_MAH" \
    'BEGIN{d=i*dt/3600.0/(cap*1000)*100; s=soc+d;
     if(s<0)s=0; if(s>100)s=100; printf "%.2f", s}')

  # 锚点 1：CV 尾段接近充满（电压高且电流已收敛）→ 校准 100%
  if [ "$st" = "Charging" ] || [ "$st" = "Full" ]; then
    if [ $mv -ge 4350 ] && [ $ma -lt 300 ]; then soc=100.00; fi
    [ "$st" = "Full" ] && soc=100.00
  fi
  # 锚点 2：放电接近截止（3.45V 空载以下）→ 校准到底
  if [ "$st" = "Discharging" ] && [ $mv -le 3450 ]; then soc=1.50; fi

  echo $soc > "$SOCF"
  echo $now > "$TSF"

  # 原子写格式化（pretty-print）JSON
  [ -z "$soc" ] && soc=0
  [ -z "$mv" ] && mv=0
  [ -z "$ma" ] && ma=0
  [ -z "$t" ] && t=0
  awk -v soc="$soc" -v mv="$mv" -v ma="$ma" -v t="$t" -v st="$st" -v cap="$CAP_MAH" -v now="$now" 'BEGIN{
    st_cn = (st=="Charging")?"充电中":(st=="Discharging")?"放电中":(st=="Full")?"已充满":(st=="Not Charging")?"未充电":"未知";
    p = mv*ma/1000000.0;
    n=int(soc/5+0.5); if(n>20)n=20; if(n<0)n=0;
    bar=""; for(j=0;j<20;j++){c=(j<n)?"█":"░"; bar=bar c};
    printf "{\n";
    printf "  \"soc\": %s,\n", soc;
    printf "  \"soc_bar\": \"%s\",\n", bar;
    printf "  \"voltage_mv\": %d,\n", mv;
    printf "  \"current_ma\": %d,\n", ma;
    printf "  \"power_w\": %.1f,\n", p;
    printf "  \"temp_c\": %.1f,\n", t/10.0;
    printf "  \"status\": \"%s\",\n", st;
    printf "  \"status_cn\": \"%s\",\n", st_cn;
    printf "  \"summary\": \"电量约%.0f%%，%s，当前功率约%.1fW\",\n", soc, st_cn, p;
    printf "  \"capacity_mah_nominal\": %d,\n", cap;
    printf "  \"kernel_locked_percent\": 50,\n";
    printf "  \"method\": \"coulomb+ocv-anchor\",\n";
    printf "  \"interval_s\": 5,\n";
    printf "  \"ts\": %d\n", now;
    printf "}\n";
  }' > "$TMP" 2>/dev/null
  mv "$TMP" "$OUT"

  sleep 5
done
