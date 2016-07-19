#iFit-Web
Web Interface for selected iFit functionalities

#INSTALLATION:
Designed for Debian class Linux systems.

sudo apt-add-repository 'deb http://packages.mccode.org/debian stable main'
sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl libsys-cpuload-perl libsys-cpu-perl libnet-dns-perl libxmu6 libxp6 sendemail
sudo apt-get install cif2hkl idl2matlab looktxt
sudo apt-get install ifit-phonons

or simpler:
sudo apt-add-repository 'deb http://packages.mccode.org/debian stable main'
sudo apt-get update
sudo apt-get install ifit-web-services

** What it does: **

install necessary packages, then
  sudo a2enmod cgi
  copy the html directory    in e.g. /var/www/html/ifit-web-services
  copy the cgi-bin directory in e.g. /usr/lib/cgi-bin
  copy the etc/config file   as e.g. /etc/ifit-web-services/config
  
** Tuning to your needs **

The computing_sqw_phonons configuration is specified in the file
  cgi-bin/computing_sqw_phonons.pl
  
Then you should adapt the lines which define:
  # number of core/cpu's to allocate to the service. 1 is serial. Requires OpenMPI.
  my $mpi          = 16;

  # the name of the SMTP server, optionally followed by the :port, as in "smtp.google.com:587"
  my $email_server = "smtp.ill.fr";
  # the name of the sender of the messages on the SMTP server. Beware the @ char to appear as \@
  my $email_from   = "XXXX\@ill.eu";
  # the password for the sender
  my $email_passwd = "XXXX";

#USAGE
open a browser and connect to:

   http://localhost/ifit-web-services

which can be accessed distantly when the server is on the net.


#CREATE LIVE DVD ISO

you can try the following tools, once the web server is running.
This way you can disseminate. But the easiest is to set-up your own system as above.

** https://sourceforge.net/projects/pinguy-os/files/ISO_Builder/


** https://launchpad.net/systemback
sudo add-apt-repository -y ppa:nemh/systemback
sudo apt-get update
sudo apt-get install systemback
sudo systemback
