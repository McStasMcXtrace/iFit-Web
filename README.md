# iFit-Web
Web Interface for selected iFit functionalities




#INSTALLATION:
sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl 
sudo apt-get install cif2hkl idl2matlab looktxt
sudo apt-get install ifit-phonons
sudo a2enmod cgi
copy the html    directory in e.g. /var/www
copy the cgi-bin directory in e.g. /usr/lib/cgi-bin

#USAGE
open a browser and connect to:

   http://localhost/index.html

which can be accessed distantly when the server is on the net.


#CREATE LIVE DVD ISO

you can try the following tools, once the web server is running.
Thi way you can disseminate.

** https://sourceforge.net/projects/pinguy-os/files/ISO_Builder/


** https://launchpad.net/systemback
sudo add-apt-repository -y ppa:nemh/systemback
sudo apt-get update
sudo apt-get install systemback
sudo systemback
