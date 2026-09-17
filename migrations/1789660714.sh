echo "Force PSR1 on the Dell XPS 13 DX13260 display and pick up its speaker firmware"

# The Sharp panel in the Panther Lake XPS 13 reports RFB storage errors in
# both Panel Replay and PSR2 selective-update modes (edge line, flashes,
# cursor lag); the hardware leaf writes a Limine drop-in forcing PSR1. The
# machine's CS35L56 speaker firmware arrives through the normal package
# upgrade (linux-firmware-cirrus) but only takes effect on a cold boot, so the
# same reboot covers both.

omarchy-hw-dell-xps13-dx13260 || exit 0

running_cmdline="${OMARCHY_RUNNING_CMDLINE:-/proc/cmdline}"
rebuild_marker="${OMARCHY_XPS13_DISPLAY_REBUILD_MARKER:-/var/lib/omarchy/migrations/1789660714}"

source "$OMARCHY_PATH/install/hardware/dell-xps13-display.sh"

# The running kernel keeps the old command line until reboot, so a marker
# records the machine-wide rebuild: another user's run before then still needs
# its own reboot-required, but must not rebuild the boot image again.
booted=" $(<"$running_cmdline") "
if [[ -f $DROP_IN ]] &&
  [[ $booted != *" xe.enable_psr2_sel_fetch=0 "* || $booted != *" xe.enable_panel_replay=0 "* ]]; then
  if [[ ! -e $rebuild_marker ]]; then
    if omarchy-cmd-present limine-mkinitcpio; then
      sudo limine-mkinitcpio
      sudo install -Dm644 /dev/null "$rebuild_marker"
    fi
  fi
  omarchy-state set reboot-required
fi
