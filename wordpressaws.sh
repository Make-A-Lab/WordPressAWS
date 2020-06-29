#!/bin/bash

# cd /tmp
# git clone https://github.com/Make-A-Lab/WordPressAWS.git
# git clone https://github.com/perusio/php-ini-cleanup.git
# chmod +x /tmp/WordPressAWS/wordpressaws.sh
# /tmp/WordPressAWS/wordpressaws.sh -h blog.make-a-lab.com -u AKIAYTZQZXFBE2F6B3OQ -p aZLJp+2eOzdzmpQVT3zDqxVfl+IjaPE/1hDT9UWR

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
DB_PASSWORD = $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)

# Install Packages
cat packages.txt | xargs sudo apt-get install
sudo add-apt-repository universe
sudo add-apt-repository ppa:certbot/certbot
sudo apt-get update
sudo apt-get install certbot python3-certbot-nginx

# Secure MariaDB installation and create wordpress database
myql --user=root <<EOF
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
sudo mv wordpress /var/www/html/wordpress

# Adjusting ownership and permissions
sudo chown -R www-data:www-data /var/www/html/wordpress/
sudo chmod -R 755 /var/www/html/wordpress/

# Configure WordPress to use the database created and improve security
sudo mv /var/www/html/wordpress/wp-config-sample.php /var/www/html/wordpress/wp-config.php

sudo tee <<EOF /var/www/html/wordpress/wp-config.php >/dev/null
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

// Disallow file edit
define( 'DISALLOW_FILE_EDIT', true );

// Amazon S3 Bucket credentials
define( 'AS3CF_SETTINGS', serialize( array(
    'provider' => 'aws',
    'access-key-id' => '$S3_ACCESS_ID',
    'secret-access-key' => '$S3_ACCESS_SECRET',
) ) );
EOF

# Configure Nginx for WordPress
sudo tee <<EOF /etc/nginx/sites-available/wordpress >/dev/null
server {
    listen 80;
    listen [::]:80;
    root /var/www/html/wordpress;
    index  index.php index.html index.htm;
    server_name  $HOST www.$HOST;


     client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?$args;        
    }

    location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass             unix:/var/run/php/php7.2-fpm.sock;
    fastcgi_param   SCRIPT_FILENAME $document_root$fastcgi_script_name;
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

sudo cp /var/www/html/wordpress/wp-includes/.htaccess /var/www/html/wordpress/wp-content/uploads/.htaccess