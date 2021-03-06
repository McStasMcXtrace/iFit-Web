#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

use CGI;            # use CGI.pm
use File::Temp qw/ tempfile tempdir /;
use IO::Compress::Zip qw(zip $ZipError) ;
use IPC::Open3;
use File::Basename;
use Net::Domain qw(hostname hostfqdn);
use Sys::CPU;     # libsys-cpu-perl
use Sys::CpuLoad; # libsys-cpuload-perl
use Net::SMTP;          # core Perl
use Email::Valid;
# ------------------------------------------------------------------------------
# service configuration: tune for your needs
# ------------------------------------------------------------------------------

# the name of the SMTP server, and optional port
my $smtp_server = "smtp.synchrotron-soleil.fr";
my $smtp_port   = ""; # can be e.g. 465, 587, or left blank
# the email address of the sender of the messages on the SMTP server. Beware the @ char to appear as \@
my $email_from   = "luke.skywalker\@synchrotron-soleil.eu";
# the password for the sender on the SMTP server, or left blank
my $email_passwd = "";

my $email_account= substr($email_from, 0, index($email_from, '@'));

# ------------------------------------------------------------------------------
# GET and CHECK input parameters
# ------------------------------------------------------------------------------

$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q = new CGI;    # create new CGI object
my $service="sqw_phonons";
my $safe_filename_characters = "a-zA-Z0-9_.\-";
my $safe_email_characters     = "a-zA-Z0-9_.\-@";

# configuration of the web service
my $upload_base= "/var/www/html";   # root of the HTML web server area
my $upload_dir = "$upload_base/ifit-web-services/upload"; # where to store results. Must exist.

# testing computer load
@cpuload = Sys::CpuLoad::load();
$cpunb   = Sys::CPU::cpu_count();
$cpuload0= @cpuload[0];

$host         = hostname;
$fqdn         = hostfqdn();
$upload_short = $upload_dir;
$upload_short =~ s|$upload_base/||;

$remote_ident=$q->remote_ident();
$remote_host =$q->remote_host();
$remote_addr =$q->remote_addr();
$referer     =$q->referer();
$user_agent  =$q->user_agent();
$datestring  = localtime();

# test if we are working from the local machine 127.0.0.1 == ::1 in IPv6)
if ($remote_host eq "::1") {
  $fqdn = "localhost";
  $host = $fqdn;
  $remote_host = $fqdn;
}
if ($fqdn eq "localhost") {
  $fqdn = inet_ntoa(
        scalar gethostbyname( $host || 'localhost' )
    );
  $host = $fqdn;
  $remote_host = $fqdn;
}

if ($cpuload0 > 2.5*$cpunb) { 
  error("CPU load exceeded. Current=$cpuload0. Available=$cpunb. Try later (sorry).");
}

# testing/security
if (my $error = $q->cgi_error()){
  if ($error =~ /^413\b/o) {
    error("Maximum data limit exceeded.");
  }
  else {
    error("An unknown error has occured."); 
  }
}

# now get values of form parameters
my $material       = $q->param('material');   # 1- Material structure
my $calculator     = $q->param('calculator'); # 2- Indicate the calculator
my $smearing       = $q->param('smearing');   # 3- Indicate if the material is a conductor or insulator
my $ecut           = $q->param('ecut');       # 4- Indicate the energy cut-off
my $kpoints        = $q->param('kpoints');    # 5- Indicate the K-points
my $supercell      = $q->param('supercell');  # 6- Indicate the supercell size
my $nsteps         = $q->param('nsteps');     # 7- Indicate the maximum number of iterations for SCF convergence
my $optimizer      = $q->param('optimizer');  # 8- Optimize the material structure first
my $email          = $q->param('email');      # 9- Indicate your email

my $raw            = "";  # additional options for sqw_phonons
my $smtp;
my $email_body     = "";

if ( !$material )
{
  error("There was a problem uploading your file (try a smaller file).");
}

# check input file name
my ( $name, $path, $extension ) = fileparse ( $material, '..*' );
$material = $name . $extension;
$material =~ tr/ /_/;
$material =~ s/[^a-zA-Z0-9_.\-]//g; # safe_filename_characters
if ( $material =~ /^([a-zA-Z0-9_.\-]+)$/ )
{
  $material = $1;
}
else
{
  error("Filename contains invalid characters. Allowed: '$safe_filename_characters'");
}

# check email
$email =~ s/[^a-zA-Z0-9_.\-@]//g; # safe_email_characters
if (Email::Valid->address($email)) {
  # OK
} else {
  error("This service requires a valid email. Retry with one.");
  $email="";
}

# use directory to store all results
$dir = tempdir(TEMPLATE => "sqw_phonons_XXXXX", DIR => $upload_dir);

# get a local copy of the input file
my $upload_filehandle = $q->upload("material");
open ( UPLOADFILE, ">$dir/$material" ) or error("$!");
binmode UPLOADFILE;
while ( <$upload_filehandle> )
{
  print UPLOADFILE;
}
close UPLOADFILE;

# test: smearing="metal","insulator","semiconductor"
if ($smearing ne "metal" and $smearing ne "insulator" and $smearing ne "semiconductor") {
  $smearing = "metal";
}
# test: ecut    =260 340 500 1000 1500
if ($ecut ne "260" and $ecut ne "340" and $ecut ne "500"  and $ecut ne "1000" and $ecut ne "1500" and $ecut ne "2000") {
  $ecut = "340";
}
# test: kpoints =0 2 3 4 5 6
if ($kpoints ne "0" and $kpoints ne "2" and $kpoints ne "3" and $kpoints ne "4" and $kpoints ne "5" and $kpoints ne "6") {
  $kpoints = "0";
}
# test: supercell=2 3 4
if ($supercell ne "0" and $supercell ne "2" and $supercell ne "3" and $supercell ne "4" and $supercell ne "5" and $supercell ne "6") {
  $supercell = "0";
}
# test: optimizer
if ($optimizer ne "MDmin") {
  $optimizer = "[]";
}

# specific calculators
if ($calculator eq "ABINIT_JTH") {
  $calculator = "ABINIT";
  $raw        = "pps=pawxml;";
}
if ($calculator eq "ABINIT_GBRV") {
  $calculator = "ABINIT";
  $raw        = "pps=paw;";
}

# test: calculator=EMT,QuantumEspresso,ABINIT,GPAW,ELK,VASP
if ($calculator ne "EMT" and $calculator ne "QuantumEspresso" and $calculator ne "QuantumEspresso_ASE" and $calculator ne "ABINIT"  and $calculator ne "GPAW" and $calculator ne "ELK" and $calculator ne "VASP") {
  $calculator = "QuantumEspresso_ASE";
}

$dir_short    = $dir;
$dir_short    =~ s|$upload_base/||;

# ------------------------------------------------------------------------------
# DO the work
# ------------------------------------------------------------------------------
    
# test if the email service is valid
if ($email and $smtp_port) {
  $smtp= Net::SMTP->new($smtp_server); # e.g. port 25
} else {
  $smtp= Net::SMTP->new($smtp_server, Port=>$smtp_port);
}
if ($smtp and $email) {
  # prepare email parts
  $email_body   = <<"END_MESSAGE";
Hello $email !
  
Your calculation:
   service:    $service on machine $fqdn
   date:       $datestring
   material:   $material
   calculator: $calculator
   options:    
      occupations = $smearing
      kpoints     = $kpoints
      nsteps      = $nsteps
      ecut        = $ecut
      supercell   = $supercell
      optimizer   = $optimizer

Access the calculation report at
  http://$fqdn/$dir_short/sqw_phonons.html
  http://$fqdn/$dir_short/ (all generated files)
  
including the log file at
  http://$fqdn/$dir_short/ifit.log
  
All past and present computations at
  http://$fqdn/$upload_short/$service.html
  
Thanks for using ifit-web-services. (c) E.Farhi, Synchrotron SOLEIL.
END_MESSAGE

} else { $email = ""; }

# assemble calculation command line
$cmd = "'try;sqw_phonons('$dir/$material','$calculator','occupations=$smearing;kpoints=$kpoints;nsteps=$nsteps;ecut=$ecut;supercell=$supercell;target=$dir;optimizer=$optimizer;$raw','report');catch ME;disp('Error when executing sqw_phonons');disp(getReport(ME));end;exit'";

# launch the command for the service

# dump initial material file
$res = system("cat $dir/$material > $dir/ifit.log");
# initial email
if ($smtp and $email) {
  if ($email_passwd) {
    $smtp->auth($email_from,$email_passwd);
  }
  $smtp->mail($email_from);
  $smtp->recipient($email);
  $smtp->data();
  $smtp->datasend("From: $email_from\n");
  $smtp->datasend("To: $email\n");
  # could add CC to internal monitoring address $smtp->datasend("CC: address\@example.com\n");
  $smtp->datasend("Subject: [iFit-Web-Services] Computation: $material:$calculator STARTED [$dir_short]\n");
  # $smtp->datasend("Content-Type: text/html; charset=\"UTF-8\" \n");
  $smtp->datasend("\n"); # end of header
  $smtp->datasend($email_body);
  $smtp->datasend("\n** COMPUTATION JUST STARTED **\n");
  # attach the material
  my $file_content = do{local(@ARGV,$/)="$dir/$material";<>};
  $smtp->datasend("\nInitial lattice definition (file: $material)\n");
  $smtp->datasend("---------------------------------------------------------------------\n");
  $smtp->datasend($file_content);
  $smtp->dataend;
  $smtp->quit;
}

# the computation starts... 
$res = system("ifit -nodesktop \"$cmd\" >> $dir/ifit.log 2>&1 &");

# file used for monitoring the service usage
$filename = "$upload_dir/$service.html";

# display computation results
print $q->header ( );
print <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>$service: Thanks! [$fqdn]</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <img alt="iFit" title="iFit"
        src="http://ifit.mccode.org/images/iFit-logo.png"
        align="right" width="116" height="64">
  <img
          alt="the SOLEIL Synchrotron" title="SOLEIL"
          src="http://ifit.mccode.org/images/logo_soleil.png"
          align="right" border="0" height="64">
  <h1>$service: Phonon dispersions in 4D</h1>
  <p>Thanks for using our service <b>$service</b>
  <ul>
  <li><b>Service</b>: <a href="$referer" target="_blank">$fqdn/ifit-web-services</a> $service</li>
  <li><b>Input configuration</b>: <a href="http://$fqdn/$dir_short/$material" target="_blank">$material</a></li>
  <li><b>Command</b>: $cmd</li>
  <li><b>Status</b>: STARTED $datestring (current machine load: $cpuload0)</li>
  <li><b>From</b>: $email $remote_addr $remote_host
  </ul></p>
  <p>Results will be available on this server at <a href="http://$fqdn/$dir_short">$dir_short</a>.<br>
  You can now view:<ul>
  <li>a <a href="http://$fqdn/$dir_short/sqw_phonons.html" target="_blank">report on this calculation</a> to look at the current status and results.</li>
  <li>a <a href="http://$fqdn/$dir_short/" target="_blank">data files for this calculation</a>.</li>
  <li>the <a href="http://$fqdn/$dir_short/ifit.log" target="_blank">Log file</a>.</li>
  <li>the <a href="http://$fqdn/$upload_short/$service.html" target="_blank">report on the $service usage</a> (with current and past computations).</li>
  </ul>
  </p>
  <p>WARNING: Think about getting your data back upon completion, as soon as possible. There is no guaranty we keep it.</p>
END_HTML

if ($email ne "") {
  print <<END_HTML;
  <p>You should receive an email at $email when the computation ends.</p>
END_HTML
} else {
  print <<END_HTML;
  <p>Keep the reference <a href="http://$host/$dir_short" target="_blank">http://$host/$dir_short</a> safe 
  to be able to access your data when computation ends, as you will not be informed when it does. 
  Check regularly. In practice, the computation should not exceed a few hours for 
  most simple systems, but could be a few days for large ones (e.g. 50-100 atoms).</p>
END_HTML
}
print <<END_HTML;
  <hr>
  Powered by <a href="http://ifit.mccode.org" target="_blank">iFit</a> E. Farhi (c) 2019.<br>
  </body>
  </html>
END_HTML

# add an entry in the list of computations
if (not -f $filename) {
  # the table file does not exist. Create it
  open($fh, '>', $filename);
  printf $fh <<END_HTML;
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <title>$service: Usage report [$fqdn]</title>
  <style type="text/css">
  img {border: none;}
  </style>
  </head>
  <body>
  <img alt="iFit" title="iFit"
        src="http://ifit.mccode.org/images/iFit-logo.png"
        align="right" width="116" height="64">
  <img
          alt="the SOLEIL Synchrotron" title="SOLEIL"
          src="http://ifit.mccode.org/images/logo_soleil.png"
          align="right" border="0" height="64">
  <h1><a href="http://$fqdn/ifit-web-services" target="_blank">$service</a>: usage</h1>
  This page reports on past and current computations.
  <ul>
    <li>machine: <a href="http://$fqdn/ifit-web-services" target="_blank">$fqdn</a></li>
    <li>service: $service</li>
  </ul>
  <table style="width:100%">
  <tr>
    <th>URL</th>
    <th>Material</th>
    <th>Calculator</th> 
    <th>User</th>
    <th>Options</th>
    <th>Log</th>
    <th>Start Date</th>
  </tr>
END_HTML
} else {
  open($fh, '>>', $filename);
}
printf $fh <<END_HTML;
  <tr>
    <td><a href="http://$fqdn/$dir_short/" target="_blank"><img src="http://$fqdn/$dir_short/Phonon_0KLE.png" width="50" height="50"><img src="http://$fqdn/$dir_short/Phonon_DOS.png" width="50" height="50">$dir_short</a></td>
    <td><a href="http://$fqdn/$dir_short/$material" target="_blank"><img src="http://$fqdn/$dir_short/configuration.png" width="50" height="50">$material</a></td>
    <td>$calculator</td>
    <td><a href="mailto:$email">$email</a> from $remote_addr</td>
    <td>$raw occupations=$smearing<br>\nkpoints=$kpoints<br>\necut=$ecut<br>\nsupercell=$supercell</td>
    <td><a href="http://$fqdn/$dir_short/ifit.log" target="_blank">Log file</a></td>
    <td>$datestring</td>
  </tr>
END_HTML

close $fh;

# -----------------------------------------------------------
 sub download {
   my $file = $_[0] or return(0);
 
   # Uncomment the next line only for debugging the script 
   #open(my $DLFILE, '<', "$path_to_files/$file") or die "Can't open file '$path_to_files/$file' : $!";
 
   # Comment the next line if you uncomment the above line 
   open(my $DLFILE, '<', "$file") or return(0);
   $base = basename($file);
   # this prints the download headers with the file size included
   # so you get a progress bar in the dialog box that displays during file downloads. 
   print $q->header(-type            => 'application/x-download',
                    -attachment      => $file,
                    -Content_length  => -s "$file",
   );
 
   binmode $DLFILE;
   print while <$DLFILE>;
   undef ($DLFILE);
   $q->end_html;
   return(1);
}

 sub error {
   print $q->header(-type=>'text/html'),
         $q->start_html(-title=>"$service: Error [$fqdn]"),
         $q->h3("$service: Error: $_[0]"),
         $q->h4("$fqdn: Current machine load: $cpuload0"),
         $q->h4("<a href='http://$fqdn/$upload_short/$service.html'>Report on the $service usage</a> (with current and past computations)"),
         $q->end_html;
   exit(0);
}
