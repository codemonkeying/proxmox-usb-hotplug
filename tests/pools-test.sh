#!/bin/bash
# Offline test for process_pools: fake /sys/bus/usb/devices, stub qm, fake conf.
# Never touches real VMs. Run: bash tests/pools-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SYS=$T/sys; CONF=$T/110.conf; mkdir -p $SYS $T/bin
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; echo "  conf:"; sed 's/^/    /' $CONF; fi; }

# stub qm: config / status / set --usbN val / set --delete usbN ; logs every set
cat > $T/bin/qm <<EOF
#!/bin/bash
C=$CONF
case "\$1" in
  config) echo "name: p16kde"; cat \$C ;;
  status) echo "status: running" ;;
  set) shift 2
       if [ "\$1" = --delete ]; then sed -i "/^\$2:/d" \$C; echo "DEL \$2" >> $T/ops
       else s=\${1#--}; sed -i "/^\$s:/d" \$C; echo "\$s: \$2" >> \$C; echo "SET \$s \$2" >> $T/ops; fi ;;
esac
EOF
printf '#!/bin/bash\ncat\n' > $T/bin/logger; chmod +x $T/bin/*
export PATH=$T/bin:$PATH

dev(){ mkdir -p $SYS/$1; echo 1038 > $SYS/$1/idVendor; echo 1430 > $SYS/$1/idProduct; }
undev(){ rm -rf $SYS/$1; }

# load daemon functions without running the main loop
src=$(sed -e '/^case "\${1:-}" in/,$d' "$HERE/usb-mapping-daemon.sh" \
      | sed -e "s#/sys/bus/usb/devices#$SYS#g" -e 's#^source .*usb-mapping-helper.sh.*#:#')
LOG_FILE=$T/log; STATE_FILE=$T/state; LOCK_FILE=$T/lock; CONFIG_FILE=/nonexistent
eval "$src"
LOG_FILE=$T/log; LOCK_FILE=$T/lock; POOLS_CONF=$T/pools.conf
get_gpu_vm(){ echo 110; }
qm_config_safe(){ qm config "$1"; }
run(){ : > $T/ops; process_pools >/dev/null; }
slot_of(){ grep -E "^usb[0-9]+: host=$1(,|$)" $CONF | cut -d: -f1; }
n_pool(){ grep -cE '^usb[0-9]+: host=1-' $CONF; }

base_conf(){ cat > $CONF <<'EOC'
usb0: mapping=shared-logi-keyboard
usb1: mapping=shared-integrated-webcam
usb2: mapping=shared-gen2-audio
usb3: mapping=shared-brio500-webcam
usb4: mapping=shared-logi-mouse
usb5: mapping=shared-Btooth6
EOC
}

echo "== 1. today's bug: yubi in usb7, dongle A in usb6, B unattached (legacy 6-field line)"
echo 'steelseries 1038:1430 shared 6 2 usb3' > $T/pools.conf
base_conf; echo 'usb6: host=1-5.3.3.4.1,usb3=1' >> $CONF; echo 'usb7: mapping=shared-yubi,usb3=1' >> $CONF
dev 1-5.3.3.4.1; dev 1-5.3.3.4.4
run
ok "A stays in usb6"               '[ "$(slot_of 1-5.3.3.4.1)" = usb6 ]'
ok "B attached to usb8"            '[ "$(slot_of 1-5.3.3.4.4)" = usb8 ]'
ok "yubi untouched in usb7"        'grep -qx "usb7: mapping=shared-yubi,usb3=1" $CONF'
ok "exactly one op (SET usb8)"     '[ "$(cat $T/ops)" = "SET usb8 host=1-5.3.3.4.4,usb3=1" ]'
run
ok "steady state: no ops"          '[ ! -s $T/ops ]'

echo "== 2. unplug A: only A's slot freed, B does NOT move"
undev 1-5.3.3.4.1; run
ok "usb6 deleted"                  '! grep -q "^usb6:" $CONF'
ok "B still usb8"                  '[ "$(slot_of 1-5.3.3.4.4)" = usb8 ]'
ok "one op (DEL usb6)"             '[ "$(cat $T/ops)" = "DEL usb6" ]'

echo "== 3. replug A on another port: takes lowest free (usb6), B unchanged"
dev 1-6.2; run
ok "A' in usb6"                    '[ "$(slot_of 1-6.2)" = usb6 ]'
ok "B still usb8"                  '[ "$(slot_of 1-5.3.3.4.4)" = usb8 ]'

echo "== 4. max_devices respected (3rd identical device not attached)"
dev 1-7; run
ok "still 2 pool slots"            '[ "$(n_pool)" = 2 ]'
ok "no op for 3rd device"          '[ ! -s $T/ops ]'
undev 1-7

echo "== 5. manual host= slot for a different device is never touched"
echo 'usb9: host=2-1.4' >> $CONF; run
ok "usb9 manual kept"              'grep -qx "usb9: host=2-1.4" $CONF'

echo "== 6. daemon restart (POOL_OWNED empty), legacy range: stale usb6 ghost in range removed"
POOL_OWNED=(); undev 1-6.2; run
ok "ghost usb6 removed"            '! grep -q "^usb6:" $CONF'
ok "B adopted, stays usb8"         '[ "$(slot_of 1-5.3.3.4.4)" = usb8 ]'
ok "manual usb9 still kept"        'grep -qx "usb9: host=2-1.4" $CONF'

echo "== 7. new 5-field format"
echo 'steelseries 1038:1430 shared 2 usb3' > $T/pools.conf
POOL_OWNED=(); base_conf; dev 1-5.3.3.4.1; run
ok "both attached, lowest free"    '[ "$(slot_of 1-5.3.3.4.1)" = usb6 ] && [ "$(slot_of 1-5.3.3.4.4)" = usb7 ]'
ok "usb3=1 applied"                'grep -qx "usb7: host=1-5.3.3.4.4,usb3=1" $CONF'

echo "== 8. VM full (14 slots used): no attach, logged once"
POOL_OWNED=(); : > $CONF; for i in $(seq 0 13); do echo "usb$i: mapping=x$i" >> $CONF; done; : > $T/log; run; run
ok "no op"                         '[ ! -s $T/ops ]'
ok "logged once per device"        '[ "$(grep -c "no free usb slot" $T/log)" = 2 ]'

echo "== 9. syntax"
ok "bash -n"                       'bash -n "$HERE/usb-mapping-daemon.sh"'

echo "SUMMARY pools-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
