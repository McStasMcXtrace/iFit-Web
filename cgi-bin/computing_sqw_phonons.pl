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

# ------------------------------------------------------------------------------
# service configuration: tune for your needs
# ------------------------------------------------------------------------------

# number of core/cpu's to allocate to the service. 1 is serial. Requires OpenMPI.
my $mpi          = 16;
# the name of the SMTP server, optionally followed by the :port, as in "smtp.google.com:587"
my $email_server = "smtp.ill.fr";
# the email address of the sender of the messages on the SMTP server. Beware the @ char to appear as \@
my $email_from   = "XXXX\@ill.eu";
# the password for the sender on the SMTP server
my $email_passwd = "XXXX";

my $email_account= substr($email_from, 0, index($email_from, '@'));

# ------------------------------------------------------------------------------
# GET and CHECK input parameters
# ------------------------------------------------------------------------------

$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q = new CGI;    # create new CGI object
my $service="sqw_phonons";
my $safe_filename_characters = "a-zA-Z0-9_.-";
my $safe_email_characters     = "a-zA-Z0-9_.-@";

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

if ( !$material )
{
  error("There was a problem uploading your file (try a smaller file).");
}

# check input file name
my ( $name, $path, $extension ) = fileparse ( $material, '..*' );
$material = $name . $extension;
$material =~ tr/ /_/;
$material =~ s/[^$safe_filename_characters]//g;
if ( $material =~ /^([$safe_filename_characters]+)$/ )
{
  $material = $1;
}
else
{
  error("Filename contains invalid characters. Allowed: '$safe_filename_characters'");
}

# check email
$email =~ s/[^$safe_email_characters]//g;
if ( $email =~ /^([$safe_email_characters]+)$/ )
{
  $email = $1;
}
else
{
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
# test: kpoints =2 3 4 5 6
if ($kpoints ne "2" and $kpoints ne "3" and $kpoints ne "4" and $kpoints ne "5" and $kpoints ne "6") {
  $kpoints = "3";
}
# test: supercell=2 3 4
if ($supercell ne "2" and $supercell ne "3" and $supercell ne "4" and $supercell ne "5" and $supercell ne "6") {
  $supercell = "2";
}
# test: supercell=2 3 4
if ($optimizer ne "MDmin" or $calculator eq "QuantumEspresso") {
  $optimizer = "";
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
  $calculator = "QuantumEspresso";
}

$dir_short    = $dir;
$dir_short    =~ s|$upload_base/||;

# ------------------------------------------------------------------------------
# DO the work
# ------------------------------------------------------------------------------
    
# test if the email service is valid
if ($email_server ne "" and $email_from ne "" and $email_passwd ne "" and $email_passwd ne "XXXX") {
  # prepare email parts
  $email_body1   = <<"END_MESSAGE";
Hello $email !
  
Your calculation:
   service:    $service on machine $fqdn
   material:   $material (attached)
   calculator: $calculator
   options:    occupations=$smearing;kpoints=$kpoints;nsteps=$nsteps;ecut=$ecut;supercell=$supercell;optimizer=$optimizer
END_MESSAGE

  $email_body2   = <<"END_MESSAGE";

Access the calculation report at
  http://$fqdn/$dir_short
and the log file at
  http://$fqdn/$dir_short/ifit.log
All past and present computations at
  http://$fqdn/$upload_short/$service.html
  
Thanks for using ifit-web-services. (c) E.Farhi, ILL.
END_MESSAGE
  # We assemble the messages and the command using sendemail
  $email_subject_start = "$service:$material:$calculator just started on $fqdn";
  $email_subject_end   = "$service:$material:$calculator just ended on $fqdn";

  $email_body_start    = <<"END_MESSAGE";
$email_body1
   date:       STARTING on $datestring.
$email_body2
END_MESSAGE
  $email_body_end    = <<"END_MESSAGE";
$email_body1
   date:       started on $datestring, just ENDED. 
   
   Log file and initial structure are attached.
$email_body2
END_MESSAGE

  # initial and final emails can be sent. We assemble the message and the command using sendemail
  $email_cmd_end = "sendemail -f $email_from -t $email -o tls=yes -u '$email_subject_end' -m '$email_body_end' -s $email_server -xu $email_account -xp $email_passwd -a $dir/ifit.log -a $dir/$material";
  $email_cmd_start= "sendemail -f $email_from -t $email -o tls=yes -u '$email_subject_start' -m '$email_body_start' -s $email_server -xu $email_account -xp $email_passwd -a $dir/$material";
} else { $email = ""; }

# assemble calculation command line
$cmd = "'try;sqw_phonons('$dir/$material','$calculator','occupations=$smearing;kpoints=$kpoints;nsteps=$nsteps;ecut=$ecut;supercell=$supercell;mpi=$mpi;target=$dir;optimizer=$optimizer;$raw','report');catch ME;disp('Error when executing sqw_phonons');disp(getReport(ME));end;exit'";

# launch the command for the service

# dump initial material file
$res = system("cat $dir/$material > $dir/ifit.log");
# start command, handle possible email
if ($email ne "") {
  $res = system("{ $email_cmd_start; ifit \"$cmd\"; $email_cmd_end; } >> $dir/ifit.log 2>&1 &");
} else {
  $res = system("ifit \"$cmd\" >> $dir/ifit.log 2>&1 &");
}

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
          alt="the ILL" title="the ILL"
          src="http://ifit.mccode.org/images/ILL-web-jpeg.jpg"
          align="right" border="0" width="68" height="64">
  <h1>$service: Phonon dispersions in 4D</h1>
  <p>Thanks for using our service <b>$service</b>
  <ul>
  <li><b>Service</b>: <a href="$referer" target="_blank">$fqdn/ifit-web-services</a> $service</li>
  <li><b>Input configuration</b>: <a href="http://$fqdn/$dir_short/$material" target="_blank">$material</a></li>
  <li><b>Command</b>: $cmd</li>
  <li><b>Status</b>: STARTED $datestring on $mpi cpu's (current machine load: $cpuload0)</li>
  <li><b>From</b>: $email $remote_addr
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
  Powered by <a href="http://ifit.mccode.org" target="_blank">iFit</a> E. Farhi (c) 2016.<br>
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
          alt="the ILL" title="the ILL"
          src="http://ifit.mccode.org/images/ILL-web-jpeg.jpg"
          align="right" border="0" width="68" height="64">
  <h1><a href="$fqdn/ifit-web-services" target="_blank">$service</a>: usage</h1>
  This page reports on past and current computations.
  <ul>
    <li>machine: <a href="$fqdn/ifit-web-services" target="_blank">$fqdn</a></li>
    <li>service: $service</li>
    <li>allocated resources: $mpi cpu's</li>
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
    <td><a href="http://$fqdn/$dir_short/" target="_blank"><img src="http://$fqdn/$dir_short/Phonons3D.png" width="50" height="50"><img src="http://$fqdn/$dir_short/Phonons_DOS.png" width="50" height="50">$dir_short</a></td>
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
