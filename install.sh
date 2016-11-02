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
openssl dhparam -out /etc/nginx/dh4096.pem 4096

echo 'Setting up directory structure'
mkdir -p /var/www/public_html
chown -R nginx:nginx /var/www/public_html
restorecon -rv /var/www
mkdir ${NGINX_ROOT}/conf.d-enabled
mv ${NGINX_ROOT}/nginx.conf ${NGINX_ROOT}/nginx.conf.orig
cp ssl.conf ${NGINX_ROOT}
cp srv-php.conf ${NGINX_ROOT}
cp srv-static.conf ${NGINX_ROOT}
cp srv-upstream.conf ${NGINX_ROOT}
cp nginx.conf ${NGINX_ROOT}
cp conf.d/host.conf ${NGINX_ROOT}/conf.d
ln -s /etc/nginx/conf.d/host.conf /etc/nginx/conf.d-enabled

echo 'Adding firewall rules for HTTP and HTTPS traffic'
firewall-cmd --add-service http --permanent
firewall-cmd --add-service https --permanent
firewall-cmd --reload

echo 'Fixing permissions'
restorecon -Rv /etc/nginx
restorecon -Rv /var/www

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
ln -s /opt/dehydrated/certs /etc/nginx/ssl

echo 'Testing Nginx config'
nginx -t

echo "Nginx config seems to work fine. You can start Nginx with 'systemctl start nginx.service'."
