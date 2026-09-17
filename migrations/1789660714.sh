echo "Force PSR1 on the Dell XPS 13 DX13260 display and pick up its speaker firmware"

# The Sharp panel in the Panther Lake XPS 13 reports RFB storage errors in
# both Panel Replay and PSR2 selective-update modes (edge line, flashes,
# cursor lag); the hardware leaf writes a Limine drop-in forcing PSR1. The
# machine's CS35L56 speaker firmware arrives through the normal package
# upgrade (linux-firmware-cirrus) but only takes effect on a cold boot, so the
# same reboot covers both.

omarchy-hw-dell-xps13-dx13260 || exit 0

drop_in="${OMARCHY_XPS13_DISPLAY_DROP_IN:-/etc/limine-entry-tool.d/dell-xps13-dx13260-display.conf}"
running_cmdline="${OMARCHY_RUNNING_CMDLINE:-/proc/cmdline}"

source "$OMARCHY_PATH/install/hardware/dell-xps13-display.sh"

# Another user's run of this migration may already have rebuilt the boot image;
# the running kernel keeps the old command line until reboot, so check the
# drop-in against what is booted rather than re-running the rebuild blindly.
if [[ -f $drop_in ]] && ! grep -q 'xe.enable_panel_replay=0' "$running_cmdline"; then
  omarchy-cmd-present limine-mkinitcpio && sudo limine-mkinitcpio
  omarchy-state set reboot-required
fi
