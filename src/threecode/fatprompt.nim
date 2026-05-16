## High-level fat-prompt module.
##
## Controllers should import this module and drive the fat prompt through the
## operations exported here. Lower-level frame construction and visual-model
## helpers live under `fatprompt/`.

import fatprompt/[rendering, runtime]

export rendering, runtime
