#!/bin/sh

set -eu

export NGINX_ROOT=/etc/nginx

function deploy_selinux_policy
{
    MODULE=${1}

    # this will create a .mod file
    checkmodule -M -m -o ${MODULE}.mod ${MODULE}.te

    # this will create a compiled semodule
    semodule_package -m ${MODULE}.mod -o ${MODULE}.pp

    # this will install the module
    semodule -i ${MODULE}.pp
}

if [ ! -d "/root/.acme.sh" ]
then
    echo 'Error! The /root/.acme.sh directory does not exist!'
    echo 'Make sure to install acme.sh and obtain a certificate before running this script.'
    exit 1
fi

echo 'Installing SELinux prerequisites'
yum install setools-console checkpolicy policycoreutils policycoreutils-python

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

if [ -e dh4096.pem ]
then
    cp dh4096.pem ${NGINX_ROOT}
else
    echo 'Generating a DH parameters file'
    openssl dhparam -out ${NGINX_ROOT}/dh4096.pem 4096
fi

echo 'Setting up directory structure'
mkdir -p /var/www/html
chown -R nginx:nginx /var/www/html
restorecon -rv /var/www
mkdir -p ${NGINX_ROOT}/certs
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
mkdir -p ${NGINX_ROOT}/certs/${HNAME}

case ${METHOD} in
    php)
        echo 'Installing PHP dependencies'
        yum install php-fpm php-pdo php-mysql
        echo 'Configuring PHP-FPM'
        sed -i 's@listen = 127.0.0.1:9000@listen = /var/run/php-fpm/php-fpm.sock@' /etc/php-fpm.d/www.conf
        sed -i 's@;listen.owner = nobody@listen.owner = nobody@' /etc/php-fpm.d/www.conf
        sed -i 's@;listen.group = nobody@listen.group = nobody@' /etc/php-fpm.d/www.conf
        sed -i 's@user = apache@user = nginx@' /etc/php-fpm.d/www.conf
        sed -i 's@group = apache@group = nginx@' /etc/php-fpm.d/www.conf
        systemctl enable php-fpm.service
        systemctl start php-fpm.service
        echo 'Fixing document root'
        sed -i "s@#root /var/www/html;@root /var/www/html;@g" ${NGINX_ROOT}/conf.d/host.conf
        ;;

    static)
        echo 'Fixing document root'
        sed -i "s@#root /var/www/html;@root /var/www/html;@g" ${NGINX_ROOT}/conf.d/host.conf
        ;;

    upstream)
        echo 'Fixing SELinux permissions'
        deploy_selinux_policy 'nginx-centos-proxy'
        ;;

esac

echo 'Symlinking acme.sh certificates'
ln -s "/root/.acme.sh/${HNAME}/fullchain.cer" "${NGINX_ROOT}/certs/${HNAME}/fullchain.pem"
ln -s "/root/.acme.sh/${HNAME}/${HNAME}.key" "${NGINX_ROOT}/certs/${HNAME}/privkey.pem"

echo 'Fixing SELinux permissions'
deploy_selinux_policy 'nginx-centos-pid'
semanage fcontext --add -t cert_t "/root/.acme.sh(/.*)?"
restorecon -rv "/root/.acme.sh"
restorecon -rv ${NGINX_ROOT}
restorecon -rv /var/www

echo 'Testing Nginx config'
nginx -t

echo "Nginx config seems to work fine. You can start Nginx with 'systemctl start nginx.service'."
echo "To keep yourself up-to-date, make sure to regularly perform 'git -C /etc/nginx/upstream'."
