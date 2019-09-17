# iFit-Web
Web Interface for selected iFit functionalities

INSTALLATION
============

Designed for Debian class Linux systems.

- sudo apt-add-repository 'deb http://packages.mccode.org/debian stable main'
- sudo apt update
- sudo apt install apache2 libapache2-mod-perl2 libcgi-pm-perl libsys-cpuload-perl libsys-cpu-perl libnet-dns-perl libxmu6 libxp6 sendemail
- sudo apt install cif2hkl idl2matlab looktxt
- sudo apt install ifit-phonons
- sudo apt install qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils qemu spice-html iptables dnsmasq libproc-processtable-perl 
- sudo adduser www-data kvm
- sudo chmod 755 /etc/qemu-ifup
- copy the html directory content into /var/www/html/ifit-web-services
- copy the cgi-bin directory content into /usr/lib/cgi-bin
- sudo chown -R www-data /var/www/html/ifit-web-services
- sudo a2enmod cgi

or simpler:
- sudo apt-add-repository 'deb http://packages.mccode.org/debian stable main'
- sudo apt-get update
- sudo apt-get install ifit-web-services

What it does
------------

assuming all required packages have been installed:
- sudo a2enmod cgi
- copy the html directory as e.g. /var/www/html/ifit-web-services
- copy the cgi-bin directory content into /usr/lib/cgi-bin
  
Tuning to your needs
====================

Phonons
-------

The computing/sqw_phonons configuration is specified in the file:
- cgi-bin/computing_sqw_phonons.pl
  
Then you should adapt the lines which define:
- \# number of core/cpu's to allocate to the service. 1 is serial. Requires OpenMPI.
- my $mpi          = 16;
- \# the name of the SMTP server, optionally followed by the :port, as in "smtp.google.com:587"
- my $email_server = "smtp.ill.fr";
- \# the name of the sender of the messages on the SMTP server. Beware the @ char to appear as \@
- my $email_from   = "XXXX\@ill.eu";
- \# the password for the sender
- my $email_passwd = "XXXX";

Virtual Machines
----------------

The cloud/virtual machine is specified in the files:
- html/cloud/virtualmachines/index.html
- cgi-bin/cloud_vm.pl

In the HTML file, add as many `<option value="blah">description</option>` lines as needed where the
"blah" should correspond with a `blah.qcow2` or `blah.iso` file in the e.g. 
/var/www/html/ifit-web-services/upload area. We provide a very small ISO as
example (Damn Small Linux). 

In the cloud_vm.pl file, adapt the name of the SMTP server and sender email account. 
Beware the @ char to appear as \@.

USAGE
=====

open a browser and connect to:
-  http://localhost/ifit-web-services

which can be accessed distantly when the server is on the net.

