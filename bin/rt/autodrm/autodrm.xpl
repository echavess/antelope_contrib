#   Copyright (c) 1999 Boulder Real Time Technologies, Inc.           
#                                                                     
#   This software module is wholly owned by Boulder Real Time         
#   Technologies, Inc. Any use of this software module without        
#   express written permission from Boulder Real Time Technologies,   
#   Inc. is prohibited.                                               

use Getopt::Std ;
 
if ( ! getopts('dD:p:v') )
    { die ( "Usage: $0 [-dv] [-D dir] [-p pf] [files]\n" ) ; }

use Datascope ;
use Mail::Internet ;

if ( $opt_D ) { 
    chdir $opt_D ; 
}

$VersionId = "GSE2.1" ;

$Pf = $opt_p ? $opt_p : "autodrm" ;

$Environment{'receipt'} = $receipt = now() ;

@request = <> ; 
close STDIN ;


if ( ! -d "tmp" ) { 
    mkdir "tmp", 0775 || die ( "can't create working directory 'tmp'\n" ) ;
}
$LOCKFILE = "tmp/lockfile" ;
open(LOCK, ">$LOCKFILE" ) ||
    die ( "Can't open autodrm lock file $LOCKFILE" ) ;
flock (LOCK, 2) || die ( "Can't lock $LOCKFILE for sequential autodrm processing" ) ;

$request = Mail::Internet->new(\@request) ;
chomp($from = $request->get('From' )) ; 
$Environment{'e-mail'} = $from ;
$Environment{'msg_type'} = "request" ;
$Environment{'msg_id'} = "no-msg-id" ;
$Environment{'source_code'} = "no-source-code" ;
$Environment{'ftp'} = 0 ;
$Environment{'to'} = $receipt ;
$Environment{'time_stamp'} = 0 ;
$bull_type = pfget($Pf, "default_bulletin_type" ) ; 
if ( $bull_type ne "" ) {
    $Environment{'bull_type'} = $bull_type ; 
}
$Environment{'max_email_size'} = pfget($Pf, "max_email_size" ) ; 	
$Environment{'max_ftp_size'} = pfget($Pf, "max_ftp_size" ) ; 	
$Reference_coordinate_system = pfget($Pf, "reference_coordinate_system" ) ; 

$reply_id_format = pfget($Pf, "reply_id_format") ; 
$reply_id_timezone = pfget($Pf, "reply_id_timezone") ;
$Environment{'reply_id'} = $reply_id = 
	epoch2str($receipt, $reply_id_format, $reply_id_timezone) ;

$return_address = $Environment{'return_address'} = 
	pfget($Pf, "return_address" ) ;

$Network = pfget($Pf, "Network" ) ; 

$No_loopback = '(/=-#$%^+@.*.@+^%$#-=\)' ; 

@std_preface = (" This response was generated by Antelope autodrm", 
   ' from Boulder Real Time Technologies, Inc.', 
   '', 
   ' For instructions in the use of this server, please',
   ' reply to this mail with the message "please help".',
   "\t$No_loopback\t",
   ) ; 
$Prefix = "  ->" ;

if ( ! $opt_d || ! -e "/dev/tty" || ! -t STDIN ) {
    $Log = &log_output(pfget($Pf, "error-log") ) ;
} 

check_for_loopback(@request) ; 

if ( grep (/^DATA_TYPE\s|^MSG_TYPE\s+DATA/i, @request ) ) { 
    $dir = pfget($Pf, "incoming_replies_directory" ) ; 
    if ( $dir ne "" ) { 
	open ( REPLY, ">$dir/$reply_id" ) ; 
	print REPLY @request ; 
	close REPLY ; 
	$merge_db = pfget ($Pf, "incoming_database" ) ;
	$program = pfget ( $Pf, "incoming_program" ) ;
	if ( $merge_db ne "" && $program ne "" ) { 
	    system ( "$program $dir/$reply_id $merge_db" ) ; 
	}
	$result = -99 ;
	&log_reply($request, $receipt, $reply_id, $reply, $result ) ;
    }
} else { 
    if ( pfget($Pf, "save_requests" )) { 
	if ( ! -d requests ) { 
	    mkdir "requests", 0775 ; 
	}
	open ( REQUEST, ">requests/$reply_id" ) ;
	print REQUEST @request ;
	close REQUEST ;
    }

    if ( $from ne "" && &ok($from) ) { 
	($result, $reply) = form_reply ( $request, $reply_id ) ; 
	 $reply->replace('To',$Environment{'e-mail'});
	 $reply->replace('From',$Environment{'return_address'});
	 if ( defined $Environment{'subject'} ) { 
	     $reply->replace('Subject', $Environment{'subject'});
	 } else { 
	     $reply->replace('Subject', "Antelope AutoDRM Response : $Environment{'msg_id'}" ) ; 
	 }

	if ( $opt_d ) {
	    $reply->print(\*STDERR) ;
	} else { 
	    @recipients = $reply->smtpsend() ;
	    if ( @recipients == 0 ) { 
		print STDERR "failed to send reply to $Environment{'e-mail'}\n" ;
	    }
	    if ( pfget($Pf, "save_replies" )) { 
		if ( ! -d replies ) { 
		    mkdir "replies", 0775 ; 
		}
		open ( REQUEST, ">replies/$reply_id" ) ;
		$reply->print(\*REQUEST) ;
		print REQUEST @request ;
		close REQUEST ;
	    }
	}
	&log_reply($request, $receipt, $reply_id, $reply, $result ) ;
    } else { 
	print STDERR "mail from $from rejected\n" ;
	foreach $_ (@request) { 
	    if ( /MSG_ID\s+(\S+)\s*(\S+)?/i ) {
		$Environment{'msg_id'} = $1 ;
		$Environment{'source_code'} = $2 ;
	    }
	}
	$reply = Mail::Internet->new([]) ;
	$result = -1 ;
	&log_reply($request, $receipt, $reply_id, $reply, $result ) ; 
    }
}

check_diskspace(pfget($Pf, "minimum_free_space" )) ;
cleanup_logs() ;
flock(LOCK, 8); # unlock lock file
exit(0) ;

sub check_for_loopback {
    my (@input) = @_ ; 
    if ( grep(index($_,$No_loopback)>=0, @input)) {
	my $msg = "The following request was rejected as loopback mail:\n" ;
	print STDERR $msg ; 
	unshift ( @input, $msg ) ; 
	chomp(@input) ;
	&notify_operator( \@input ) ;
	$reply = Mail::Internet->new([]) ;
	$result = -1 ;
	&log_reply($request, $receipt, $reply_id, $reply, $result ) ; 
	exit(0) ;
    }

    if ((@input > 10 && grep (/^BEGIN\b/i, @input) < 1)) {  
	my $msg = "The following request was rejected as misdirected or possibly spam:\n" ;
	print STDERR $msg ; 
	unshift ( @input, $msg ) ; 
	chomp(@input) ;
	&notify_operator( \@input ) ;
	$reply = Mail::Internet->new([]) ;
	$result = -1 ;
	&log_reply($request, $receipt, $reply_id, $reply, $result ) ; 
	exit(0) ;
    }

}

sub check_diskspace { 
    my ($disk_minspace) = @_ ; 
    open ( DF, "/bin/df -k .|" ) ; 
    my $result = "" ;
    while ( <DF> ) { 
	next if /^Filesystem/ ;
	$result .= " " . $_ ; 
    }
    my ( $filesystem, $kbytes, $used, $avail, $capacity, $mountpt) = split(' ', $result) ;
    if ( $avail < $disk_minspace ) { 
	my @msg = ( "autodrm disk partition has only $avail kbytes free", 
		    "It should have $disk_minspace kbytes free" ) ; 
	&notify_operator( \@msg ) ;
    }
}

sub cleanup_logs { 
    my $request_expiration_age = pfget($Pf, "request_expiration_age" ) ; 
    my $reply_expiration_age = pfget($Pf, "reply_expiration_age" ) ; 

    my @old = () ;
    if ( -d "requests" ) { 
	open ( OLD, "cd requests ; find . -xdev -type f -mtime +$request_expiration_age|" ) ; 
	while ( <OLD> ) { 
	    chomp;
	    push(@old, "requests/$_") ; 
	}
	if ( @old > 0 ) { 
	    print STDERR "deleting old requests: @old\n" ;
	    unlink @old ;
	}
    }

    @old = () ;
    if ( -d "replies" ) { 
	open ( OLD, "cd replies ; find . -xdev -type f -mtime +$reply_expiration_age|" ) ; 
	while ( <OLD> ) { 
	    chomp;
	    push(@old, "replies/$_") ; 
	}
	if ( @old > 0 ) { 
	    print STDERR "deleting old replies: @old\n" ;
	    unlink @old ;
	}
    }
}

sub form_reply { 
    my ( $request, $reply_id) = @_ ;

    my @reply = () ; 
    my $reply_preface = pfget($Pf, "reply_preface" ) ; 
    my @reply_preface = split('\n', $reply_preface) ;
    push (@reply, @reply_preface ) ;
    push (@reply, "") ; 
    push (@reply, @std_preface ) ;
    push (@reply, "") ; 

    push (@reply, "BEGIN $VersionID") ; 
    push (@reply, "MSG_TYPE DATA") ; 
    my $source_code = pfget($Pf, "source_code") ;
    push (@reply, "MSG_ID $reply_id $source_code") ; 

    ($result, $logref, $resultref) = &process_body ( $request->body) ;

    push (@reply, "REF_ID $Environment{'msg_id'} $Environment{'source_code'}") ;
    push (@reply, "" ) ;

# append Log output

    if ( $result != 0 ) {
	push (@reply, "DATA_TYPE ERROR_LOG GSE2.1" ) ;
	push (@reply, "$Prefix Some problems occurred during processing." ) ; 
    } else { 
	push (@reply, "DATA_TYPE LOG GSE2.1" ) ;
	push (@reply, "$Prefix Your request was processed successfully." ) ; 
    }

    push (@reply, "$Prefix Following is a log of your request." ) ;
    push (@reply, @$logref ) ;

# append results
    push (@reply, @$resultref) ;

# end with STOP
    push (@reply, "\nSTOP" ) ;
    grep (s/$/\n/, @reply ) ;


    my $reply = $request->reply() ;
    my $ref = $reply->body() ;
    @$ref = @reply ; 
    return ($result, $reply) ; 
}

sub log_reply { 
    my ( $request, $receipt, $reply_id, $reply, $result ) = @_ ;


    my $in_kbytes = &kbytes ( $request->body ) ;
    my $out_kbytes = &kbytes ( $reply->body ) ;
    my $database = pfget($Pf, "log_database" ) ;
    my $schema = pfget($Pf, "log_schema" ) ; 
    if ( ! -e $database ) { 
	open ( DB, ">$database" ) ; 
	print DB "#\nschema	$schema\n" ; 
	close DB ; 
    }
    my @db = dbopen ( $database, "r+" ) ; 
    @db = dblookup ( @db, 0, "log", 0, 0 ) ; 

    my $code ;
    if ( $result == 0 ) { 
	$code = 's' ; 
    } elsif ( $result == -99 ) {
	$code = 'd' ; 
    } elsif ( $result > 0 ) { 
	$code = 'e' ; 
    } else {
	$code = 'r' ; 
    }

    $db[3] = dbaddnull(@db) ; 
    dbputv (@db, "email", $Environment{'e-mail'},
	    "msg_id", $Environment{'msg_id'}, 
	    "msg_type", substr($Environment{'msg_type'}, 0, 1), 
	    "receipt", $receipt,
	    "version", $Environment{'version'}, 
	    "source_code", $Environment{'source_code'}, 
	    "in_kbytes", $in_kbytes, 
	    "result", $code, 
	    "rsp_id", $reply_id, 
	    "out_kbytes", $out_kbytes, 
	    "disposal", now() ) ; 
}

sub kbytes { 
    my ( $ref ) = @_ ; 
    my ($line, $cnt) ;
    $cnt = 0 ;
    foreach $line ( @$ref ) {
	$cnt += length ( $line ) ; 
    }
    return $cnt/1024. ;
}

sub process_body {
    my ( $ref ) = @_ ; 
    my @body = @$ref ;
    my @log = () ;
    my @result = () ; 
    my $result = 0 ; 
    my $process = 0 ;
    my $start_command_time ;
    my @empty = () ;

    $Database = pfget($Pf, "database_for_requests" ) ; 
    @Db = dbopen ( $Database, "r" ) ; 

    my (@db, $n) ;
    foreach $table ( qw(site sensor sitechan instrument) ) { 
	@db = dblookup (@Db, 0, $table, 0, 0 ) ; 
	$n = dbquery (@db, "dbRECORD_COUNT" ) ;
	if ( $n < 1 ) { 
	    push(@log, errlog("Database is incorrect or not present: no $table table") ) ; 
	    $result++ ; 
	    $Notify_operator = 1;
	}
    }
    push (@log, "" ) if $result ;

    while ( $_ = shift @body ) {
	chomp; 
	push (@log, "% $_") ;
	if (/^BEGIN\s*(\S+)?/i ) {
	    $Environment{'version'} = $1 ;
	    $process = 1 ;

	} elsif (/^STOP/i ) {
	    $process = 0 ;

	} elsif ( /\b(HELP|GUIDE|INFOR\w*)\b/i && ! /^(MSG_ID)/) {
	    &send_help() ;
	    push (@log, "$Prefix sent guide to $Environment{'e-mail'}\n" ) ; 

	} elsif ( /^(E-MAIL|EMAIL|E_MAIL)\s+(.*)/i ) {
		$Environment{'e-mail'} = $2 ;
	}

	if ( $opt_V ) { 
	    if ( $process ) { 
		print STDERR "-> $_\n" ; 
	    } else { 
		print STDERR "## $_\n" ; 
	    }
	}

	if ( $process ) { 
	    $start_command_time = now() ;
	    $subresult = 0 ; 
	    $logref = \@empty ;
	    $resultref = \@empty ;


	    if ( /^%/ | /^\s*$/ ) {  
		next ;  # skip comments and blank lines

	    } elsif ( /^(BEGIN|STOP|E-MAIL|EMAIL|E_MAIL|HELP)/i ) {
		next ;  # handled above

# Environment Variables
	    } elsif ( /MSG_TYPE\s+(\S+)/i ) { 
		$Environment{'msg_type'} = $1 ;
	    } elsif ( /MSG_ID\s+(\S+)?\s+(\S+)/i ) { 
		$Environment{'msg_id'} = $1 ;
		$Environment{'source_code'} = $2 ;

	    } elsif ( /REF_ID\s+(\S+)?\s+(\S+)/i ) { 
		$Environment{'ref_id'} = $1 ;
		$Environment{'ref_source_code'} = $2 ;

	    } elsif ( /^TIME\s+(.*)\s*\bTO\b\s*(.*)/i ) { 
		$Environment{'from'} = str2epoch($1) ;
		$Environment{'to'} = str2epoch($2) ;
		&push_timerange(\@log) ;
	    } elsif ( /^TIME\s+(.*)/i ) { 
		$Environment{'from'} = $1 ; 
		&push_timerange(\@log) ;

	    } elsif ( /^LAT\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'low_lat'} = $1 ? $1 : -90.0 ;
		$Environment{'high_lat'} = $2 ? $2 : 90.0 ;
		push (@log, "$Prefix Latitude range is $Environment{'low_lat'} to $Environment{'high_lat'} degrees." ) ;

	    } elsif ( /^LON(G)?\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'low_lon'} = $2 ? $2 : -180.0 ;
		$Environment{'high_lon'} = $3 ? $3 : 180.0 ;
		push (@log, "$Prefix Longitude range is $Environment{'low_lon'} to $Environment{'high_lon'} degrees." ) ;

	    } elsif ( /^EVENT_STA_DIST\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'low_dist'} = $1 ? $1 : 0.0 ;
		$Environment{'high_dist'} = $2 ? $2 : 180.0 ;
		push (@log, "$Prefix Event to station distance range is $Environment{'low_dist'} to $Environment{'high_dist'} degrees." ) ;

	    } elsif ( /^DEPTH\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'shallow'} = $1 ? $1 : 0.0 ;
		$Environment{'deep'} = $2 ? $2 : 6400.0 ;
		push (@log, "$Prefix Depth range is $Environment{'shallow'} to $Environment{'deep'} kilometers deep." ) ;

	    } elsif ( /^DEPTH_MINUS_ERROR\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'shallow_90'} = $1 ? $1 : 0.0 ;
		$Environment{'deep_90'} = $2 ? $2 : 6400.0 ;
		push (@log, "$Prefix 90% probability depth range is $Environment{'shallow_90'} to $Environment{'deep_90'} kilometers deep." ) ;

	    } elsif ( /^MAG\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'low_mag'} = $1 ? $1 : -10.0 ;
		$Environment{'high_mag'} = $2 ? $2 : 20.0 ;
		push (@log, "$Prefix Magnitude range is $Environment{'low_mag'} to $Environment{'high_mag'}." ) ;

	    } elsif ( /^MAG_TYPE\s+(.*)/i ) { 
		@list = to_list($1) ;
		my @bad = grep (!/^(mb|Ms|ML)$/, @list) ; 
		if ( @bad > 0 ) { 
		    push (@log, &errlog("magnitude types '@bad' not recognized"));
		}
		my $i ;
		my @ok=() ;
		foreach $i ( @list ) { 
		    push @ok, "mb" if ( $i eq "mb" ) ;
		    push @ok, "ms" if ( $i eq "Ms" ) ;
		    push @ok, "ml" if ( $i eq "ML" ) ;
		}

		$Environment{'mag_type'} = join(' ', @ok) ;
		push (@log, "$Prefix Magnitude types are $Environment{'mag_type'}." ) ;

	    } elsif ( /^MB_MINUS_MS\s+(.*)?\s*TO\b\s*(.*)?/i ) { 
		$Environment{'low_mag_diff'} = $1 ? $1 : 0.0 ;
		$Environment{'high_mag_diff'} = $2 ? $2 : 20.0 ;
		push (@log, "$Prefix Difference between mb and Ms Magnitudes range is $Environment{'low_mag_diff'} to $Environment{'high_mag_diff'}." ) ;

	    } elsif ( /^NET_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'net_list'} = join(' ', @list) ;
		push (@log, "$Prefix networks to include are $Environment{'net_list'}." ) ;

	    } elsif ( /^STA_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'sta_list'} = join(' ', @list) ;
		push (@log, "$Prefix stations to include are $Environment{'sta_list'}." ) ;

	    } elsif ( /^CHAN_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'chan_list'} = join(' ', @list) ;
		push (@log, "$Prefix channels to include are $Environment{'chan_list'}." ) ;

	    } elsif ( /^BEAM_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'beam_list'} = join(' ', @list) ;
		push (@log, "$Prefix beams to include are $Environment{'beam_list'}." ) ;
	    } elsif ( /^AUX_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'aux_list'} = join(' ', @list) ;
		push (@log, "$Prefix auxiliary ids to include are $Environment{'aux_list'}." ) ;

	    } elsif ( /^BULL_TYPE\s+(\S+)/i ) { 
		$Environment{'bull_type'} = $1 ;

	    } elsif ( /^GROUP_BULL_LIST\s+(\S+)/i ) { 
		@list = to_list($1) ;
		$Environment{'group_bull_list'} = join(' ', @list) ;

	    } elsif ( /^ARRIVAL_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'arrival_list'} = join(' ', @list) ;
		push (@log, "$Prefix arrival ids to include are $Environment{'arrival_list'}." ) ;

	    } elsif ( /^ORIGIN_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'origin_list'} = join(' ', @list) ;
		push (@log, "$Prefix origin ids to include are $Environment{'origin_list'}." ) ;

	    } elsif ( /^EVENT_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'event_list'} = join(' ', @list) ;
		push (@log, "$Prefix event ids to include are $Environment{'event_list'}." ) ;

	    } elsif ( /^COMM_LIST\s+(.*)/i ) { 
		@list = to_list($1) ;
		$Environment{'comm_list'} = join(' ', @list) ;
		push (@log, "$Prefix communication links to include are $Environment{'comm_list'}." ) ;

	    } elsif ( /^RELATIVE_TO\s+(\S+)/i ) { 
		$Environment{'relative_to'} = $1 ;

	    } elsif ( /^TIME_STAMP/i ) { 
		$Environment{'time_stamp'} = 1 ;

	    } elsif ( /^FTP\s+(\S+)/i ) { 
		$Environment{'e-mail'} = $1 ;
		$Environment{'ftp'} = 1 ;
	    } elsif ( /^FTP/i ) { 
		$Environment{'ftp'} = 1 ;

# Unimplemented commands
	    } elsif ( /^INTER\s+(\S+)/i ) { 
		$result++ ; 
		push (@log, &errlog("ftp transfer to $1 not supported"));
		$Environment{'ftp'} = 1 ;

# Actual data returned
	    } elsif ( /^DATA_TYPE\s+(\S+)?\s*(\S+)?/i ) { 
		$type = $1 ;
		$format = $2 ;
		($subresult, $logref, $resultref) = &data_type($type,$format) ;

# Actual data requests

	    } elsif ( /^WAVEFORM\b\s*(.*)/i ) { 
		($subresult, $logref, $resultref) = &waveform($1) ;

	    } elsif ( /^WAVEF\s+(.*)/i ) { 
		$save = $Environment{'sta_list'} ;
		$Environment{'sta_list'} = $1 ;
		($subresult, $logref, $resultref) = 
			&waveform($Environment{'version'}) ;
		$Environment{'sta_list'} = $save ;

	    } elsif ( /^STATION\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &station($1) ;

	    } elsif ( /^CHANNEL\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &channel($1) ;

	    } elsif ( /^RESPONSE\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &response($1) ;

	    } elsif ( /^BULLETIN\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &bulletin($1) ;

	    } elsif ( /^ORIGIN\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &origin($1) ;

	    } elsif ( /^ARRIVAL\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &arrival($1) ;

	    } elsif ( /^DETEC\S*\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &detections($1) ;

	    } elsif ( /^CALIB\b\s*(.*)?/i ) { 
		$save = $Environment{'sta_list'} ;
		$Environment{'sta_list'} = $1 ;
		($subresult, $logref, $resultref) = 
			&response($Environment{'version'});
		$Environment{'sta_list'} = $save ;

	    } elsif ( /^OUTAGE\b\s*(.*)?/i ) { 
		($subresult, $logref, $resultref) = &outage($1) ;

	    } elsif ( /^(TITLE|SUBJE\S*)\s+(.*)/i ) { 
		$Environment{'subject'} = $2 ;
		
# Anything else (an error)
	    } else {
		$result++ ;
		push (@log, &errlog("'$_' <not recognized>" ) ); 
		($cmd, $rest) = split (' ', $_, 2 ) ; 
		$cmd = lc($cmd) ;
		if ( $ref = pfget($Pf, "examples{$cmd}")) {
		    if ( /^\s+/ ) { 
			push (@log, "$Prefix requests must start in column one.\n" ) ;
		    }
		    push (@log, "$Prefix The correct syntax for $cmd is:" ) ;
		    if ( !ref($ref) ) {
			push (@log, "$Prefix   '$ref'" ) ;
		    } elsif ( ref($ref) eq "SCALAR" ) {
			push (@log, "$Prefix   '$$ref'" ) ;
		    } elsif ( ref($ref) eq "ARRAY" ) {
			@examples = @$ref ;
			foreach $example ( @examples ) {
			    push (@log, "$Prefix   '$example'" ) ;
			}
		    }
		}
		$line = pop(@log) ; 
		$line .= "\n" ; 
		push(@log, $line) ;
	    }

	    if ( @$logref + @$resultref > 0 || $subresult != 0 ) { 
		if ( $Environment{'time_stamp'} ) { 
		    push (@result, "\ntime_stamp " . 
			epoch2str($start_command_time,"%Y/%m/%d %H:%M:%S",""));
		}

		$result += $subresult ; 
		push(@log, @$logref) ;
		if ( @$resultref > 0 ) { 
		    $result_kbytes = &kbytes ( @$resultref ) + &kbytes(@result) ;
		    if ( $result_kbytes < $Environment{'max_email_size'}) {
			push(@result, "" ) ;
			push(@result, @$resultref) ;
		    } else { 
			push (@log, "$Prefix maximum message size $Environment{'max_email_size'} exceeded" ) ;
			push (@log, "$Prefix   result data omitted") ; 
			$Excessive_size = 1 ;
		    }
		}
	    }
	}
    }
    if ( $Environment{'time_stamp'} ) { 
	push (@result, "\ntime_stamp " . 
	    epoch2str(now(),"%Y/%m/%d %H:%M:%S",""));
    }
    &notify_operator( \@log ) if $Notify_operator ;
    push ( @log, "$Prefix The operator has been alerted to the errors above." ) if $Notify_operator ;
    return ($result, \@log, \@result ) ; 
}

sub ok { 
    my ( $from ) = @_ ;

    my $ref = pfget($Pf, "allow") ; 
    my @allow = @$ref ;

    my $ref = pfget($Pf, "deny") ; 
    my @deny = @$ref ;

    my $re ;
    my $ok = 1 ;
    if ( @allow > 0 ) { 
	$ok = 0 ;
	foreach $re (@allow) {
	    if ( $from =~ /$re/i ) { 
		$ok = 1 ; 
		last ;
	    }
	}
    }

    foreach $re (@deny) {
	if ( $from =~ /$re/i ) { 
	    $ok = 0 ; 
	    last ;
	}
    }
    return $ok ; 
}

sub send_help { 

    my $help = pfget($Pf, "help_msg" ) ;
    open ( HELP, $help ) || &notify_operator ( "Can't open '$help'" ) ;
    my $mail = Mail::Internet->new(\*HELP) ;
    $mail->replace('To',$Environment{'e-mail'});
    $mail->replace('From',$Environment{'return_address'});
    $mail->replace('Subject', "User's Guide to Antelope_autodrm" ) ; 
    if ( $opt_d ) { 
	print STDERR ">> would send help response as follows:\n" ; 
	$mail->print(\*STDERR) ;
	print STDERR ">>\n" ;
    } else {
	my @recipients = $mail->smtpsend() ;
	if ( @recipients == 0 ) { 
	    print STDERR "failed to send help to $Environment{'e-mail'}\n" ;
	}
    }
}

sub notify_operator { 
    my ( $msg ) = @_ ; 
    my $time_str = epoch2str($receipt, "%a %B %d, %Y %H:%M:%S", "" ) ;

    my @body = () ; 

    push (@body, 
	"An error occurred while processing request $Environment{'msg_id'}\n");
    push (@body, "received from $Environment{'e-mail'} at $time_str\n\n" ) ; 
    if ( ref($msg) eq "ARRAY" ) { 
	push (@body, "\nThe resulting error log is:\n" );
	push (@body, "\n---------------------------------------\n") ;
	my @log = @$msg ; 
	grep(s/$/\n/, @log) ;
	grep(s/^/> /, @log) ;
	push (@body, @log) ; 
	push (@body, "---------------------------------------\n\n") ;

    } else {
	push (@body, " 	$msg\n\n" ) ;
    }
    push (@body, "The return reply id is $Environment{'reply_id'}\n") ;

    my $note = Mail::Internet->new(\@body) ;
    my $operator = pfget($Pf, "operator" ) ; 
    $note->replace ('To', $operator ) ; 
    $note->replace('From',$Environment{'return_address'});
    $note->replace('Subject', "autodrm: errors during request processing" ) ; 

    if ( $opt_d ) { 
	print STDERR "\nSend following error message to '$operator'\n" ;
	print STDERR "***********************************************\n" ;
	$note->print(\*STDERR) ;
	print STDERR "***********************************************\n\n" ;
    } else { 
	@recipients = $note->smtpsend() ;
	if ( @recipients == 0 ) { 
	    $note->replace ('To', "root" ) ; 
	    $note->replace ('Cc', "mailer-daemon" ) ; 
	    @recipients = $note->smtpsend() ;
	}
    }
}

sub log_output {   
    my ($log) = @_ ;
    if ( ! $opt_d ) { 
	open(STDOUT, ">$log") || die "Can't redirect stdout";
	open(STDERR, ">&STDOUT") || die "Can't dup stdout";
	select(STDERR); $| = 1;     # make unbuffered
	select(STDOUT); $| = 1;     # make unbuffered
    }
    return $log ;
}

sub errlog { 
    my ($msg) = @_ ; 
    return "$Prefix *** $msg ***" ;
}

sub list2re { 
    my ($list) = @_ ; 
    if ( $list ne "*" ) { 
	$list =~ s/ /|/g ; 
	$list =~ s/\*/.*/g ; 
    } else { 
	$list = undef ;
    }
    return $list ;
}

sub data_type { 
    my ( $type, $format) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("DATA_TYPE '$type' not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub data_for { 
    my ( $sta_chan, $record, $reflog, $refresult, @dbwf ) = @_ ;

    if ( $record >= 0 ) { 
	push(@$refresult, "WID2 $sta_chan" ) ; 
	push(@$refresult, "STA2" ) ;
	if ( /relative_to/ ) { 
	    push(@$refresult, "EID2" ) ;
	}
	if ( /beam/ ) { 
	    push(@$refresult, "BEA2" ) ;
	}
	push(@$refresult, "DAT2" ) ;
	push(@$refresult, "CHK2" ) ;
    } else { 
	push(@$refresult, "OUT2 $sta_chan" ) ;
	push(@$refresult, "STA2" ) ;
    }
}

sub subset_net {
    my (@db) = @_ ;
    my ($re, $n) ;
    if ( defined $Environment{'net_list'} ) { 
	$re = list2re($Environment{'net_list'}) ;
	if ( $Network !~ /$re/ ) { 
	    $db[1] = -102 ;
	}
    }
    return @db ; 
}

sub subset_sta {
    my (@db) = @_ ;
    my ($re, $n) ;
    if ( defined $Environment{'sta_list'} ) { 
	$re = list2re($Environment{'sta_list'}) ;
	@db = dbsubset(@db, "sta =~/$re/" ) if $re ;
    }
    return @db ; 
}

sub subset_chan {
    my (@db) = @_ ;
    my ($re, $n) ;
    if ( defined $Environment{'chan_list'} ) { 
	$re = list2re($Environment{'chan_list'}) ;
	@db = dbsubset(@db, "chan =~/$re/" ) if $re ;
    }
    return @db ; 
}

sub subset_lat {
    my (@db) = @_ ;
    my ($lo, $hi, $subset, $n) ;
    if ( defined $Environment{'low_lat'} ) { 
	$lo = $Environment{'low_lat'} ; 
	$hi = $Environment{'high_lat'} ; 
	$subset = "lat >= $lo && lat <= $hi" ; 
	@db = dbsubset(@db, $subset) ; 
    }
    return @db ; 
}

sub subset_lon {
    my (@db) = @_ ;
    my ($lo, $hi, $subset, $n) ;
    if ( defined $Environment{'low_lon'} ) { 
	$lo = $Environment{'low_lon'} ; 
	$hi = $Environment{'high_lon'} ; 
	if ( $lo < $hi ) { 
	    $subset = "lon >= $lo && lon <= $hi" ; 
	} else { 
	    $subset = "(lon >= $lo && lon < 180) || (lon > -180 && lon < $hi)" ;
	}
	@db = dbsubset(@db, $subset) ; 
    }
    return @db ; 
}

sub subset_date_or_now {
    my (@db) = @_ ;
    my ($from, $to, $n) ;
    if ( defined $Environment{'from'} ) { 
	$from = $Environment{'from'} ; 
	$to = $Environment{'to'} ; 
    } else { 
	$from = time() - 86400 ;
	$to = time() ;
    }
    $from = &yearday($from) ; 
    $to = &yearday($to) ; 
    @db = dbsubset(@db, "(ondate>= $from && (offdate<= $to|| offdate==NULL)) || ($from >=ondate && ($from <offdate || offdate == NULL))" ) ;
    return @db ; 
}

sub subset_time_or_now {
    my (@db) = @_ ;
    my ($from, $to, $n) ;
    if ( defined $Environment{'from'} ) { 
	$from = $Environment{'from'} ; 
	$to = $Environment{'to'} ; 
    } else { 
	$to = $from = time() ;
	$from -= 86400 ;
    }
    @db = dbsubset(@db, "(time>= $from && time<= $to) || ($from >=time && $from <endtime)" ) ;
    return @db ; 
}

sub subset_date {
    my (@db) = @_ ;
    my ($from, $to, $n) ;
    if ( defined $Environment{'from'} ) { 
	$from = $Environment{'from'} ; 
	$to = $Environment{'to'} ; 
	$from = &yearday($from) ; 
	$to = &yearday($to) ; 
	@db = dbsubset(@db, "(ondate>= $from && (offdate<= $to|| offdate==NULL)) || ($from >=ondate && ($from <offdate || offdate == NULL))" ) ;
    }
    return @db ; 
}

sub subset_time {
    my (@db) = @_ ;
    my ($from, $to, $n) ;
    if ( defined $Environment{'from'} ) { 
	$from = $Environment{'from'} ; 
	$to = $Environment{'to'} ; 
	@db = dbsubset(@db, "(time>= $from && time<= $to) || ($from >=time && $from <endtime)" ) ;
    }
    return @db ; 
}

#-----------------------------------------------------------------
# Request implementation:
#      each routine returns three results:
#	 result-code which is the number of errors which occurred
#	 \@log    any log messages
#	 \@result any results
#
# Global variables which can be used:
#      @Db : the input database
#      Database	: the name of the input database
#      Reference_coordinate_system : coordinate system used for lat/lon
#      %Environment : values from the request.
#-----------------------------------------------------------------

sub origin { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub arrival { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub detection { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub alert { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub ppick { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub avail { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub slist { 
    my ( $version ) = @_ ;
    my $result = 1 ;
    my @log = ( &errlog("not implemented") ) ;
    my @result = () ; 
    return ($result, \@log, \@result ) ;
}

sub fmttime { 
    my ($time) = @_ ;
    return epoch2str($time, "%a %B %d, %Y %H:%M:%S", "UTC" ) ;
}

sub push_timerange {
    my ( $ref ) = @_ ;
    my $from = &fmttime($Environment{'from'}) ; 
    my $to = &fmttime($Environment{'to'}) ;
    push (@$ref, " $Prefix Time range is $from" ) ;
    push (@$ref, " $Prefix            to $to\n" ) ;
}

sub to_list { 
    my ( $line ) = @_ ; 
    $line =~ s/,/ /g ; 
    $line =~ s/\s+/ /g ; 
    return split ( ' ', $line) ;
}
