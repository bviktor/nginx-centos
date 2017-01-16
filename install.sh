#!/bin/sh

set -e

export NGINX_ROOT=/etc/nginx

echo 'Installing Nginx'
cat << EOF > /etc/yum.repos.d/nginx.repo
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=0
enabled=1
EOF

yum install nginx
systemctl enable nginx.service

echo 'Generating a DH parameters file'
openssl dhparam -out ${NGINX_ROOT}/dh4096.pem 4096

echo 'Setting up directory structure'
mkdir -p /var/www/public_html
chown -R nginx:nginx /var/www/public_html
restorecon -rv /var/www
mkdir -p ${NGINX_ROOT}/conf.d-enabled
mv ${NGINX_ROOT}/nginx.conf ${NGINX_ROOT}/nginx.conf.orig
cp conf.d/host.conf ${NGINX_ROOT}/conf.d
ln -s ${NGINX_ROOT}/conf.d/host.conf ${NGINX_ROOT}/conf.d-enabled

git clone https://github.com/bviktor/nginx-centos.git ${NGINX_ROOT}/upstream
pushd ${NGINX_ROOT}
ln -s upstream/ssl.conf .
ln -s upstream/srv-php.conf .
ln -s upstream/srv-static.conf .
ln -s upstream/srv-upstream.conf .
ln -s upstream/nginx.conf .
popd

echo 'Adding firewall rules for HTTP and HTTPS traffic'
firewall-cmd --add-service http --permanent
firewall-cmd --add-service https --permanent
firewall-cmd --reload

echo 'Setting up host.conf'
read -p "Hostname (FQDN): " HNAME
sed -i "s/foobar.com/${HNAME}/g" ${NGINX_ROOT}/conf.d/host.conf
read -p "Server method (php, static, upstream): " METHOD
sed -i "s/#include srv-${METHOD}/include srv-${METHOD}/g" ${NGINX_ROOT}/conf.d/host.conf
if [ ${METHOD} == 'upstream' ]
then
    echo 'Fixing SELinux permissions'
    yum install policycoreutils-python setools-console
    echo 'type=AVC msg=audit(1443806547.648:1986): avc:  denied  { name_connect } for  pid=46116 comm="nginx" dest=8080 scontext=system_u:system_r:httpd_t:s0 tcontext=system_u:object_r:http_cache_port_t:s0 tclass=tcp_socket' | audit2allow -M nginx
    semodule -i nginx.pp
fi

echo 'Symlinking dehydrated certificates'
ln -s /opt/dehydrated/certs ${NGINX_ROOT}/ssl

echo 'Setting up hpkp.conf'
mkdir -p ${NGINX_ROOT}/hpkp
pushd ${NGINX_ROOT}/hpkp

cat << EOF > hpkp.sh
#!/bin/sh

NGINX_ROOT=${NGINX_ROOT}
HPKP_AGE=10

# changing this can render your site permanently inaccessible, handle with extreme caution!
DEPLOY_HPKP=0

generate_pin ()
{
    echo -n "pin-sha256=\""
    grep -i "begin ec private key" --quiet \${1}
    USE_RSA=\$?
    if [ \${USE_RSA} -eq 1 ]
    then
        echo -n \$(openssl rsa -in \${1} -pubout 2>/dev/null | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
    else
        echo -n \$(openssl ec -in \${1} -pubout 2>/dev/null | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
    fi
    echo -n "\"; "
}

if [ \${1} == "deploy_cert" ]
then
    echo 'Regenerating public key pins using new private keys'
    if [ \${DEPLOY_HPKP} -eq 1 ]
    then
        echo -n "add_header Public-Key-Pins '" > \${NGINX_ROOT}/hpkp/hpkp.conf
    else
        echo -n "add_header Public-Key-Pins-Report-Only '" > \${NGINX_ROOT}/hpkp/hpkp.conf
    fi
    generate_pin "\${NGINX_ROOT}/ssl/\${2}/privkey.pem" >> \${NGINX_ROOT}/hpkp/hpkp.conf
    generate_pin "\${NGINX_ROOT}/ssl/\${2}/privkey.roll.pem" >> \${NGINX_ROOT}/hpkp/hpkp.conf
    echo "max-age=\${HPKP_AGE}';" >> \${NGINX_ROOT}/hpkp/hpkp.conf
fi
EOF
chmod +x hpkp.sh
sh hpkp.sh
popd

echo 'Fixing permissions'
restorecon -Rv ${NGINX_ROOT}
restorecon -Rv /var/www

echo 'Testing Nginx config'
nginx -t

echo "Nginx config seems to work fine. You can start Nginx with 'systemctl start nginx.service'."
echo "To keep yourself up-to-date, make sure to regularly perform 'git -C /etc/nginx/upstream'."
