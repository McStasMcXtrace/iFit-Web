#!/usr/bin/perl -w

# requirements:
#   sudo apt-get install apache2 libapache2-mod-perl2 libcgi-pm-perl ifit-phonons libsys-cpu-perl libsys-cpuload-perl libnet-dns-perl libproc-background-perl libproc-processtable-perl
# sudo apt install jupyter
# sudo mkdir -p /var/www/.local/share/jupyter
# sudo chown -R www-data /var/www/.local

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

use CGI;              # use CGI.pm
use File::Temp      qw/ tempfile tempdir /;
use File::Basename  qw(fileparse);
use File::Path      qw(rmtree);
use Net::Domain     qw(hostname hostfqdn);
use Net::SMTP;          # core Perl
use Sys::CPU;           # libsys-cpu-perl           for CPU::cpu_count
use Sys::CpuLoad;       # libsys-cpuload-perl       for CpuLoad::load
use Proc::Background;   # libproc-background-perl   for Background->new
use Proc::Killfam;      # libproc-processtable-perl for killfam (kill pid and children)
use Email::Valid;

# ------------------------------------------------------------------------------
# service configuration: tune for your needs
# ------------------------------------------------------------------------------

# the name of the SMTP server, and optional port
my $smtp_server  = "smtp.synchrotron-soleil.fr"; # when empty, no email is needed. token is shown.
my $smtp_port    = ""; # can be e.g. 465, 587, or left blank
# the email address of the sender of the messages on the SMTP server. Beware the @ char to appear as \@
my $email_from   = "luke.skywalker\@synchrotron-soleil.fr";
# the password for the sender on the SMTP server, or left blank
my $email_passwd = "";
my $nb_lifetime  = 600; # max Notebook life time in sec. 1 day is 86400 s.

# ==============================================================================
# DECLARE all our variables
# ==============================================================================

# CGI stuff --------------------------------------------------------------------
$CGI::POST_MAX = 1024*5000; # max 5M upload

my $q     = new CGI;    # create new CGI object
my $error = "";

# identification stuff ---------------------------------------------------------
my @cpuload = Sys::CpuLoad::load();
my $cpunb   = Sys::CPU::cpu_count();
my $cpuload0= $cpuload[0];

my $host         = hostname;
my $fqdn         = hostfqdn();
my $remote_host = $q->remote_host();
my $server_name = $q->server_name();
my $datestring  = localtime();

# service stuff ----------------------------------------------------------------
my $service     = "cloud_notebook";
my $upload_base = "/var/www/html";   # root of the HTML web server area
my $upload_dir  = "$upload_base/ifit-web-services/upload"; # where to store files. Must exist.
my $upload_short = $upload_dir;
$upload_short =~ s|$upload_base/||;

my $email       = "";

# PORT will be in 0-99.
my $port        = 8989;
my $lock_name   = ""; # filename written to indicate IP:PORT lock
my $lock_handle;
my $output      = "";
my $smtp;             # SMTP server object
my $cmd;
my $res;
my $token        = "";
my $token_handle;
my $token_name   = "";
my $proc_jupyter = "";

# ------------------------------------------------------------------------------
# first clean up any 'old' VM sessions
# ------------------------------------------------------------------------------
foreach $lock_name (glob("$upload_dir/$service.*")) {
  # test modification date for 'cloud_notebook.port' file
  if ($nb_lifetime and time - (stat $lock_name)[9] > $nb_lifetime) {
    # must kill that Jupyter. Read file content as a hash table
    my %configParamHash = ();
    if (open ($lock_handle, $lock_name )) {
      while ( <$lock_handle> ) { # read config in -> $configParamHash{key}
        chomp;
        s/#.*//;                # ignore comments
        s/^\s+//;               # trim heading spaces if any
        s/\s+$//;               # trim leading spaces if any
        next unless length;
        my ($_configParam, $_paramValue) = split(/\s*:\s*/, $_, 2);
        $configParamHash{$_configParam} = $_paramValue;
      }
    }
    close $lock_handle;
    # kill pid, pid_jupyter
    $output .= "<li>[OK] Cleaning $lock_name (time-out) in " . $configParamHash{directory} . "</li>\n";
    print STDERR "Cleaning $lock_name (time-out) " . $configParamHash{directory} . "\n";
    if ($configParamHash{pid})         { killfam('TERM',($configParamHash{pid}));        }
    if ($configParamHash{pid_jupyter}) { killfam('TERM',($configParamHash{pid_jupyter}));}
    
    # clean up files/directory
    if (-e $lock_name)                   { unlink $lock_name; }
    if (-e $configParamHash{directory})  { rmtree( $configParamHash{directory} ); }
  } # if cloud_nb.port is here
}
$lock_name = "";

# ==============================================================================
# GET and CHECK input parameters
# ==============================================================================

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
$output .= "<li>[OK] Starting on $datestring</li>\n";
$output .= "<li>[OK] The server name is $server_name.</li>\n";
$output .= "<li>[OK] You are accessing this service from $remote_host.</li>\n";

# test host load
if ($cpuload0 > 1.25*$cpunb) {
  $error .= "CPU load exceeded. Current=$cpuload0. Available=$cpunb. Try again later. ";
} else {
  $output .= "<li>[OK] Server $server_name load $cpuload0 is acceptable.</li>\n";
}

# testing/security
if (not $error) {
  if ($res = $q->cgi_error()){
    if ($res =~ /^413\b/o) {
      $error .= "Maximum data limit exceeded. ";
    }
    else {
      $error .= "An unknown error has occured. "; 
    }
  }
}

# now get values from the HTML form

# EMAIL: required to send the ID and link. check email
if (not $error and $smtp_server) {
  $email          = $q->param('email');      # 1- Indicate your email
  if (Email::Valid->address($email))
  {
    $output .= "<li>[OK] Hello <b>$email</b> !</li>";
  }
  else
  {
    $error .= "This service requires a valid email. Retry with one.";
    $email = "";
  }
}

# a test is made to see if the port has already been allocated.
# we search the 1st free port (allow up to 99)
if (not $error) {
  for ($id=1; $id<100; $id++) {
    $port        = 8987 + $id;
    $lock_name   = "$upload_dir/$service.$port";
    if (not -e $lock_name) { $id_ok = 1; last; };  # exit loop if the ID is OK
  }
  # check for the existence of the PORT.
  if (not $id_ok) { 
    $error .= "Can not assign port for session. Try again later. ";
  } else {
    $output .= "<li>[OK] Assigned port $port.</li>\n";
  }
}

# ==============================================================================
# DO the work
# ==============================================================================

# define where our stuff will be (HTML file)
# use 'upload' directory to store the temporary VM. 
# Keep it after creation so that the VM can run.
$base_name = tempdir(TEMPLATE => "$service" . "_XXXXX", DIR => $upload_dir, CLEANUP => 1);

# initiate the HTML output
# WE OPEN A TEMPORARY HTML DOCUMENT, WRITE INTO IT, THEN REDIRECT TO IT.
# The HTML document contains some text (our output).
# This way the cgi script can launch all and the web browser display is made independent
# (else only display CGI dynamic content when script ends).
$html_name = $base_name . "/index.html";
$name = fileparse ( $base_name );

if (open($html_handle, '>', $html_name)) {
  # display information in the temporary HTML file

  print $html_handle <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>$service: [$fqdn]</title>
</head>
<body>
  <img alt="iFit" title="iFit"
    src="http://$server_name/ifit-web-services/images/iFit-logo.png"
    align="right" width="116" height="64">
  <img
    alt="SOLEIL" title="SOLEIL"
    src="http://$server_name/ifit-web-services/images/logo_soleil.png"
    align="right" border="0" height="64">
  <h1>$service: Jupyter Notebook</h1>
  <img alt="Notebook" title="Notebook"
    src="http://$server_name/ifit-web-services/cloud/notebook/images/notebook.png"
    align="right" height="128" width="173">  
  <a href="http://$server_name/ifit-web-services/">iFit Web Services</a> / (c) E. Farhi Synchrotron SOLEIL (2019).
  <hr>
END_HTML
  close $html_handle;
} else {
  # this indicates 'upload' is probably not there, or incomplete installation
  $error .= "Can not open $html_name (initial open). ";
  print $error;
  exit(0);
}

# create a local Jupyter config in the newly created directory
# https://jupyter.readthedocs.io/en/latest/projects/config.html
if (not $error) {
  # create local jupyter configuration
  $cmd = "JUPYTER_CONFIG_DIR=$base_name/.jupyter jupyter notebook --generate-config";
  $res = `$cmd > /dev/null`; # EXEC

  # create the token
  # cast a random token key for Jupyter
  sub rndStr{ join'', @_[ map{ rand @_ } 1 .. shift ] };
  $token = rndStr 8, 'a'..'z', 'A'..'Z', 0..9;  # 8 random chars in [a-z A-Z digits]
  
  # file created just for the launch, removed immediately. 
  # With a temp file and redirection, the token does not appear in the process list (ps).
  $token_name = $base_name . "/token"; 
  open($token_handle, '>', $token_name);
  print $token_handle "$token\n$token\n";
  close($token_handle);
  
  # set the token.
  my $pw = "cat $token_name | python3 -c 'from notebook.auth import passwd;print(passwd(input()))'";
  $res = `$pw`; # get the hash
  
  # remove token file
  if (-e $token_name) { unlink($token_name); }
  
  # start the server (Background)
  $cmd = "JUPYTER_CONFIG_DIR=$base_name/.jupyter; cd $base_name; jupyter notebook --NotebookApp.allow_origin='*' --port=$port --ip=$remote_host --no-browser --NotebookApp.password=$res --NotebookApp.shutdown_no_activity_timeoutInt=$nb_lifetime";
  
  $proc_jupyter = Proc::Background->new($cmd);
  if (not $proc_jupyter) {
    $error .= "Could not start Jupyter server. ";
  } else {
    $output .= "<li>[OK] Started Jupyter server $remote_host:$port in http://$remote_host/ifit-web-services/upload/$name/</li>\n";
  }
  
}

# ------------------------------------------------------------------------------
# create the output message (either OK, or error), and display it.

# display information in the temporary HTML file
if (open($html_handle, '>>', $html_name)) {

  if (not $error) {
    $redirect="http://$remote_host:$port";

    print $html_handle <<END_HTML;
<ul>
$output
<li>[OK] No error, all is fine. Time-out is $nb_lifetime [s].</li>
<li><b>[OK]</b> Connect to your Jupyter session at <a href=$redirect target=_blank><b>$redirect</b></a> using the provided token.</li>
</ul>
<p>Hello $email !</p>

<p>
Your Jupyter session $service has just started. 
Open the following <a href=$redirect target=_blank>link to connect</a>. You will be requested to enter a <b>token</b>, which you should receive by email at $email.</p>
<p>
Remember that the Jupyter session is created on request, and destroyed after its time-out ($nb_lifetime [s]). You should then export any work done there-in elsewhere (e.g. mounted disk, ssh/sftp, Dropbox, OwnCloud...).
</p>
<p>
To start a Notebook, use any existing <i>ipynb</i> file or create new ones from the top right 'New' menu.
</p>

<h1><a href=$redirect target=_blank>$redirect</a></h1>

</body>
</html>
END_HTML
    close $html_handle;
    
    # we create a lock file
    if (open($lock_handle, '>', $lock_name)) {
      my $pid_jupyter = $proc_jupyter->pid();
      print $lock_handle <<END_TEXT;
date: $datestring
service: $service
pid: $$
pid_jupyter: $pid_jupyter
ip: $remote_host
port: $port
directory: $base_name
END_TEXT
      close $lock_handle;
    }
    # LOG in /var/log/apache2/error.log
    print STDERR "[$datestring] $service: start: Jupyter NoteBook on $port http://$server_name/ifit-web-services/upload/$name -> $redirect token=$token for user $email\n";
    
  } else {
    print STDERR "[$datestring] $service: ERROR: $_[0]\n";
    print $html_handle <<END_HTML;
    <ul>
      $output
      <li><b>[ERROR]</b> $error</li>
    </ul>
  </body>
  </html>
END_HTML
    close $html_handle;
  }
} else {
  $error .= "Can not open $html_name (append). ";
  print $error;
  exit(0);
}

sleep(1); # make sure the files have been created and flushed

# SEND THE HTML MESSAGE TO THE USER --------------------------------------------
if ($email) {
  if ($smtp_port) {
    $smtp= Net::SMTP->new($smtp_server); # e.g. port 25
  } else {
    $smtp= Net::SMTP->new($smtp_server, Port=>$smtp_port);
  }
  if ($smtp) {
    # read the HTML file and store it as a string
    my $file_content = do{local(@ARGV,$/)=$html_name;<>};
    $file_content .= "<h1>Use token '$token' to connect</h1>"; # add token
    
    if ($email_passwd) {
      $smtp->auth($email_from,$email_passwd) or $smtp = "";
    }
    if ($smtp) { $smtp->mail($email_from) or $smtp = ""; }
    if ($smtp) { $smtp->recipient($email) or $smtp = ""; }
    if ($smtp) { $smtp->data() or $smtp = ""; }
    if ($smtp) { $smtp->datasend("From: $email_from\n") or $smtp = ""; }
    if ($smtp) { $smtp->datasend("To: $email\n") or $smtp = ""; }
      # could add CC to internal monitoring address $smtp->datasend("CC: address\@example.com\n");
    if ($smtp) { $smtp->datasend("Subject: [iFit-Web-Services] Jupyter Notebbok connection information\n") or $smtp = ""; }
    if ($smtp) { $smtp->datasend("Content-Type: text/html; charset=\"UTF-8\" \n") or $smtp = ""; }
    if ($smtp) { $smtp->datasend("\n") or $smtp = ""; } # end of header
    if ($smtp) { $smtp->datasend($file_content) or $smtp = ""; }
    if ($smtp) { $smtp->dataend or $smtp = ""; }
    if ($smtp) { $smtp->quit or $smtp = ""; }
  }
}
if (not $smtp) {
  # when email not sent, add the token to the HTML message (else there is no output)
  if (open($html_handle, '>>', $html_name)) {
    print $html_handle <<END_HTML;
<h1>Use token '$token' to connect</h1>
END_HTML
    close $html_handle;
  }
}

# REDIRECT TO THAT TEMPORARY FILE (this is our display) ------------------------
# can be normal exec, or error message
$redirect="http://$server_name/ifit-web-services/upload/$name/index.html";
print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)
sleep(1); # make sure the display comes in.

# Jupyter to end ---------------------------------------------------
if (not $error and $proc_jupyter) { 
  $proc_jupyter->wait;
}

# CLEAN-UP temporary files (html), jupyter
END {
  print STDERR "[$datestring] $service: cleanup: Jupyter NoteBook on $port for user $email\n";
  if (-e $html_name)  { unlink $html_name; }
  if (-e $token_name) { unlink($token_name); }
  if (-e $lock_name)  { unlink $lock_name; }
  if (-e $base_name)  { rmtree(  $base_name ); } # in case auto-clean up fails
  
  # make sure Jupyter and asssigned SHELLs are killed
  if ($proc_jupyter) { killfam('TERM',($proc_jupyter->pid)); $proc_jupyter->die; }
}

# ------------------------------------------------------------------------------

