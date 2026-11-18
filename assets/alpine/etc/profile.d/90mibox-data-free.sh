# MIBOX_DATA_FREE_LOGIN_V1 (plan S4): warn at login when data space is low.
# Sourced by /etc/profile; must never end the login.
if [ -x /usr/local/bin/mibox-data-free ]; then
    /usr/local/bin/mibox-data-free -q || :
fi
