#!/bin/bash

<<COMMENT
Author: Make A Lab
Compatibility system: Ubuntu 18.04
Description: This script make the following configurations:
                - Install and configure Nginx for WordPress integration
                - Install and configure MariaDB for WordPress integration
                - Install and configure WordPress
                - Set .htaccess restrictions for basic security
                - Install and configure CertBot for SSL certificate
                - Configure S3 bucket credentials for media storage
Usage commands:

cd /tmp
git clone https://github.com/Make-A-Lab/WordPressAWS.git
git clone https://github.com/perusio/php-ini-cleanup.git
chmod +x /tmp/WordPressAWS/wordpressaws.sh
/tmp/WordPressAWS/wordpressaws.sh -h [DNS_RECORD] -u [USER_ACCESS_ID] -p [USER_ACCESS_SECRET]

COMMENT

# Pass script arguments
while getopts h:u:p: option 
do 
 case "${option}" 
 in 
 h) HOST=${OPTARG};; 
 u) S3_ACCESS_ID=${OPTARG};;
 p) S3_ACCESS_SECRET=${OPTARG};; 
 esac 
done 

# Create Random Password for Database
DB_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 22 | head -n 1)
DB_RANDOM=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
DB_PREFIX='WP_'$DB_RANDOM'_'

# Install Packages
echo '* libraries/restart-without-asking boolean true' | sudo debconf-set-selections
sudo add-apt-repository ppa:certbot/certbot -y
sudo apt-get update
cat /tmp/WordPressAWS/packages.txt | xargs sudo apt-get install -y

# Secure MariaDB installation and create wordpress database
sudo mysql --user=root <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER 'wp_user'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL ON wordpress.* TO 'wp_user'@'localhost' IDENTIFIED BY '$DB_PASSWORD' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Configure php.ini document for production thanks to @Perusio script
# More info at: https://github.com/perusio/php-ini-cleanup
/tmp/php-ini-cleanup/php_cleanup -p /etc/php/7.2/fpm/php.ini

# Download WordPress latest release
cd /tmp && wget https://wordpress.org/latest.tar.gz
tar -zxvf latest.tar.gz
sudo mv /tmp/wordpress /var/www/html/wordpress

# Adjusting ownership and permissions
sudo chown -R www-data:www-data /var/www/html/wordpress/
sudo chmod -R 755 /var/www/html/wordpress/

# Configure WordPress to use the database created and improve security
sudo mv /tmp/WordPressAWS/wp-config-sample.php /var/www/html/wordpress/wp-config.php

sudo tee -a <<EOF /var/www/html/wordpress/wp-config.php >/dev/null

/* MySQL database table prefix. */
\$table_prefix = '$DB_PREFIX';

$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

// ** MySQL settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define('DB_NAME', 'wordpress');

/** MySQL database username */
define('DB_USER', 'wp_user');

/** MySQL database password */
define('DB_PASSWORD', '$DB_PASSWORD');

/** MySQL hostname */
define('DB_HOST', 'localhost');
/** Database Charset to use in creating database tables. */
define('DB_CHARSET', 'utf8');

/** The Database Collate type. Don't change this if in doubt. */
define('DB_COLLATE', '');

/** Disallow file edit */
define('DISALLOW_FILE_EDIT', true );

/** Amazon S3 Bucket credentials */
define( 'AS3CF_SETTINGS', serialize( array(
    'provider' => 'aws',
    'access-key-id' => '$S3_ACCESS_ID',
    'secret-access-key' => '$S3_ACCESS_SECRET',
) ) );
EOF

# Configure Nginx for WordPress
sudo tee -a <<EOF /etc/nginx/sites-available/wordpress >/dev/null
server {
    listen 80;
    listen [::]:80;
    root /var/www/html/wordpress;
    index  index.php index.html index.htm;
    server_name  $HOST www.$HOST;


     client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;        
    }

    location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass             unix:/var/run/php/php7.2-fpm.sock;
    fastcgi_param   SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

# Enable WordPress Site
sudo ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/

# Restart services
sudo systemctl restart nginx.service
sudo systemctl restart php7.2-fpm.service

# Add SSL certificate
sudo certbot --nginx

# Disable PHP execution on certain folders
cat <<EOF >> /var/www/html/wordpress/wp-includes/.htaccess
<Files *.php>
deny from all
</Files>
EOF

sudo mkdir /var/www/html/wordpress/wp-content/uploads
sudo cp /var/www/html/wordpress/wp-includes/.htaccess /var/www/html/wordpress/wp-content/uploads/.htaccess