/* COpus (CL-11): the client's libopus leaf — the decode half of the
   audio path. The host's COpusEncode C leaf is the encoder mirror;
   this module exists because the system AudioConverter has no PLC
   entry point and the M7 receiver spec pins libopus PLC as the
   concealment tool. pkg-config
   `opus` (Homebrew on macOS) supplies the include path pointing INTO
   the opus header directory, hence the bare include. */
#include <opus.h>
