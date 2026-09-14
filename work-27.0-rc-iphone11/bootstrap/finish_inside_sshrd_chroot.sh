#!/var/jb/bin/sh
set -e

export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin

test -f /var/jb/.procursus_strapped
test -x /var/jb/usr/bin/dpkg
test -f /var/jb/sileo.deb

if test -x /var/jb/prep_bootstrap.sh; then
    NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh
fi

# uikittools' trigger calls uicache, which cannot load the normal System
# private-framework dyld environment from SSHRD.  The 34306 fallback is to
# verify that Sileo itself installed and then move its app from SSHRD.
if ! /var/jb/usr/bin/dpkg -i /var/jb/sileo.deb; then
    echo "dpkg returned after the expected SSHRD-only uicache trigger failure"
fi
test -x /var/jb/Applications/Sileo.app/Sileo

printf 'SILEO='
/var/jb/usr/bin/dpkg-query -W -f='${Status} ${Version}\n' org.coolstar.sileo
echo BOOTSTRAP_READY
