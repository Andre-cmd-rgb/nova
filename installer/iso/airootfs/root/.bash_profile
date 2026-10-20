# The first console starts the installer; the others (Alt+F2) are plain shells.
if [[ $(tty) == /dev/tty1 && -z ${NOVA_INSTALL_STARTED:-} ]]; then
  export NOVA_INSTALL_STARTED=1
  nova-install-start
fi
