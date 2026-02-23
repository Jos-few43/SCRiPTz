#!/bin/bash
exec distrobox enter dev-tools -- bash -c 'source /etc/profile.d/dev-tools.sh && pyright-langserver --stdio'
