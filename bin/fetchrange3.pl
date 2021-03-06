#!/usr/bin/perl -w                                                                                                                                                      

# Copyright (c) 2014-2018, Melissa Jenkins
# All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * The names of its contributors may not be used to endorse or promote products
#       derived from this software without specific prior written permission.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL MELISSA JENKINS BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 

use strict;
use threads;
use threads::shared;
use Thread::Semaphore;
use Storable;
use Carp 'verbose';

use Ham::APRS::IS;
use Ham::APRS::FAP qw(parseaprs);
use DBI;
use Data::Dumper;
use Math::Trig qw(:great_circle deg2rad rad2deg);
use FindBin;
use lib $FindBin::Bin;
use Geo::Coordinates::UTM;

use Socket qw(SOL_SOCKET SO_RCVBUF);

my $id = 'GLDDBF61';
my %countries :shared;


use LatLngCoarse2;


use JSON;

# load the configuration file
my $filename = "../config/binconfig.json";

my $json_text = do {
    open(my $json_fh, "<:encoding(UTF-8)", $filename)
	or die("Can't open \"$filename\": $!\n");
    local $/;
    <$json_fh>
};

my $json = JSON->new;
my $data = $json->decode($json_text);

my $db_dsn = $data->{config}->{dsn} || die "no dsn specified";
my $db_username = $data->{config}->{dbusername} || die "no user specified";
my $db_password = $data->{config}->{dbpassword} || die "no user specified";


#
##########
#
# Configuration
#
##########
#
my @servers = ( 'glidern1.glidernet.org:10153', 
		'glidern2.glidernet.org:10153', 
		'glidern3.glidernet.org:10153', 
		'glidern4.glidernet.org:10153', 
		'aprs.glidernet.org:10152' );
#		'glidern2.glidernet.org:10152');
#		'aprs.glidernet.org:10152' );



#
#############
#
# setup
#
#############
#
# Flush after each write
my $old_handle = select (STDOUT); # "select" STDOUT and save
                                  # previously selected handle
$| = 1; # perform flush after each write to STDOUT
select ($old_handle); # restore previously selected handle

sub NESW { my @x = (deg2rad(90 - $_[1]), deg2rad($_[0])); return \@x; };


my %stations_loc : shared; # static cache to stop too many db updates
my %stations_ver : shared;

my %stations_last : shared;
my %stations_packets : shared; # same mutex as last
my %stations_status : shared; # same mutex, flags errors like no ppm
my %stations_ppm : shared; # same mutex, counts up until we are confident of noppm
my %stats : shared; #mutex
my %gliders : shared;

# caches for the insert into db so we don't need to use text fields
my %station_id :shared;
my %station_name : shared;
my %glider_id :shared;

my $ready_semaphore = Thread::Semaphore->new(100); 
 
while(1) {
    $ready_semaphore->down(100);
    
    my $avail = threads->create( \&handleAvailablity );
    foreach my $server ( @servers ) {
	threads->create( \&handleServer, $server );
    }
    
    $avail->join();
}

##############
# connect to  server and process the data from it 
##############
sub handleServer {
    my ($server) = @_;


    # wait for us to be ready to start, we will be signalled by the availability thread once it has loaded
    # everything
    $ready_semaphore->down(1);

    my $full =  ! ($server =~ /^aprs/);

    my $db = DBI->connect( $db_dsn, $db_username, $db_password );
    if( ! $db ) {
	die "database problem". $DBI::errstr;
    }
    $db->do( 'SET time_zone = "GMT"' );


    my $sth_mgrs = $db->prepare( 'insert into positions_mgrs values ( left(now(),10), ?, ?, ?, ?, ?, 1 ) on '.
				' duplicate key update strength = greatest(values(strength),strength), '.
				' lowest = least(values(lowest),lowest), highest=greatest(values(highest),highest), '.
				' count= count+1' );

#    my $sth_crc = $db->prepare( 'insert into crc values ( now(), ?, ?, ?, ?, ?, ?, ?, ? );' );
    
    my $sth_addstation = $db->prepare( 'insert into stations ( station ) values ( ? )' );
    my $sth_updatestation = $db->prepare( 'update stations set station = ? where id = ?' );
    my $sth_addglider =  $db->prepare( 'insert into gliders ( callsign ) values ( ? )' );
    my $sth_history =  $db->prepare( 'insert into history values ( now(), ?, ?, ? )' );

    print "connecting to server $server\n";
    my $is = new Ham::APRS::IS( $server, 'OGR', 'appid' => 'ognrange.onglide.com 0.3.1');
    

    open( OUT, ">>", "/dev/null" );
#    open( OUT, ">>", $server );

    my $i = 0;
    my $lastkeepalive = time();
    my $today = date($lastkeepalive);

    while(1) {
	$is->connect('retryuntil' => 10) || print "Failed to connect: $is->{error}";

	$is->sock()->setsockopt(SOL_SOCKET,SO_RCVBUF,256*1024);
	
	while($is->connected()) {
	    	    
	    # make sure we send a keep alive every 90 seconds or so
	    my $now = time();
	    if( $now - $lastkeepalive > 60 ) {
		$is->sendline('# flarmrange.onglide.com 212.13.204.217');
		$lastkeepalive = $now;
	    }
	    
	    # check to make sure we emit the stations at least once a day
	    if( date($now) ne $today ) { 
		$today = date($now);
		%stations_loc = (); %stations_ver = ();
		print "resetting stations for change of date";
		print OUT "\n--------------- $today ---------------\n";

		# hide old stations so they don't linger forever
		$db->do( "create temporary table z as select sl.station, datediff(now(),max(sl.time)) a, least(greatest(5,count(sl.time)*2),21) b from stationlocation sl group by 1 having a > b" );
		$db->do( "update stations set active='N' where id = (select station from z where z.station = stations.id)" );
		$db->do( "drop temporary table z" );

		# ensure we have up to date coverage map once a day
		$db->do ( "truncate estimatedcoverage " );
		$db->do ( "insert into estimatedcoverage select station, ref, avg(strength) s,sum(count) c from positions_mgrs p group by station, ref having (s > 75 and c > 20) or s > 105" );
		$db->do ( "truncate roughcoverage " );
		$db->do ( "insert into roughcoverage select station, concat(left(ref,6),mid(ref,8,1)) r, avg(strength) s,sum(count) c from positions_mgrs p group by station, r " );
	    }

	    
	    my $l = $is->getline(120);
	    if (!defined $l) {
		print "\n".date($now).": $server: failed getline: ".$is->{'error'}."\n";
		$is->disconnect();
		last;
	    }
	    $i++;
	    print OUT $l."\n";

	    
	    if( $l =~ /^\s*#/ || $l eq '' ) {
#		print "\n$l\n";
		next;
	    }

	    if( $full ) {
		$l =~ /^dup\s+(.*)$/;
		print "\n->".$1."<-\n";
		$l = $1;
	    }

	    
	    my %packetdata;
	    my $retval = parseaprs($l, \%packetdata);
	    
	    if ($retval == 1) {
		
		my $callsign = $packetdata{srccallsign};
		
		# we need to do the calculation for each station that matches
		foreach my $value (@{$packetdata{digipeaters}}) {
		    while (my ($k1,$v1) = each(%{$value})) {
			
			next if( $k1 ne 'call' );
			next if( $v1 =~ /GLIDERN[0-9]/ || $v1 eq 'TCPIP' || $v1 eq 'qAS');
			
			if( $v1 ne 'qAC' ) {

			    # if we know where the glider is then we will use that
			    if( $packetdata{type} eq 'location' && 
				$packetdata{latitude} && $packetdata{longitude} ) {
				
				my $lt = $packetdata{latitude};
				my $lg = $packetdata{longitude};
				my ($lt_r,$lg_r) = makeLocationCoarse( $lt, $lg, 1000 );
				
				$lt_r = int(($lt_r * 1000)+.5)/1000;
				$lg_r = int(($lg_r * 1000)+.5)/1000;

				my $s_id = getStation( $sth_addstation, $sth_history, $sth_updatestation, $v1 );
				my $s_callsign = getGlider( $sth_addglider, $callsign );
				
				if( ($packetdata{comment}||'') =~ /([0-9.]+)dB ([0-9])e/ )  {
				    my $strength = int(($1+0) * 10);
				    my $height = int($packetdata{altitude});
				    my $direction = 1 << int(($packetdata{course}||0) / 11.25);
				    my $crc = $2+0;
				 
				    my $location = latlon_to_mgrs(23,$lt,$lg);

				    # shrink it down to what we actually want which is a subset
				    # 30UXC0006118429 -> 30UXC 00 18
				    $location =~ /^([0-9]|)([0-9][A-Z]{3}[0-9][0-9])[0-9]{3}([0-9]{2})/;
				    my $reduced = ($1||'0'); $reduced .= $2.$3;

				    # and store the record in the db
				    $sth_mgrs->execute( $s_id, $reduced, $strength, $height, $height );

				    if( $full ) {
					print "DUP: $s_callsign $s_id ($v1) lt='$lt_r' and lg='$lg_r'\n";
				    }
				    
				    {
					lock( %stations_last );

					# uptime statistics
					$stations_last{$v1} = $now;
					$stations_packets{$v1} ++;

					# overall statistics
					if( $stats{$s_id} ) {
					    $stats{$s_id}->{gliders}->{$s_callsign} = ($stats{$s_id}->{gliders}->{$s_callsign}||0)+1;
					}
					else {
					    $stats{$s_id} = shared_clone( { station => $s_id, 
									    gliders => shared_clone( { $s_callsign => 1 } ),
									    crc => ($crc >= 5 ? 1 : 0 ) } );
					}

					if( ($stations_status{$v1}||'U') eq 'N' ) {
					    print "packet from $v1 which is currently shown as noppm\n";
					    $stations_status{$v1} = 'U';
					    $stations_ppm{$v1} = 0;
					}
				    }

				    {
					lock(%gliders);
					if( ! $gliders{$s_callsign} ) {
					    $gliders{$s_callsign} = shared_clone( { $s_id => 1 } );
					}
					else {
					    $gliders{$s_callsign}->{$s_id}++;
					}
				    }
				}
				else {
				    print "*";
				    {
					lock( %stations_last );
					$stations_last{$v1} = $now;
					$stations_packets{$v1} ++;
				    }
				}

			    } # has a location
			}
			elsif( $v1 eq 'qAC' ) {

			    print "--------------------------------------------------------\n";

			    # qAC seems to be the beacons
			    my $s_id = getStation( $sth_addstation, $sth_history, $sth_updatestation, $callsign );
			    
			    if( $packetdata{type} eq 'location' && 
				$packetdata{latitude} && $packetdata{longitude} ) {

				print "location beacon $l\n";

				processStationLocationBeacon( $db, $callsign, $s_id, $packetdata{latitude}, $packetdata{longitude}, $packetdata{altitude}, $packetdata{comment}||'' );

				if( $packetdata{comment} && $packetdata{comment} =~ /v0.2.[0-5]/ ) {
				    print "OLD details beacon $///$packetdata{comment}l\n";
				    processStationDetailsBeacon( $db, $callsign, $s_id, $packetdata{comment});
				}
			    }
			    else {
				print "details beacon $l\n";
				processStationDetailsBeacon( $db, $callsign, $s_id, $l );
			    }
			}
			elsif( $packetdata{'type'} eq 'status' ) {
			    #		    print "status: $l\n";
			}
			else {
			    print "\n--- new packet ---\n$l\n";
			    while (my ($key, $value) = each(%packetdata)) {
				print "$key: $value\n";
			    }
			}
		    }
		}
	    }
	    else {
		print "\n$server: --- bad packet --> \"$l\"\n";
		warn "Parsing failed: $packetdata{resultmsg} ($packetdata{resultcode})\n";
	    }
	}
	print "\nreconnecting\n";
	$is->disconnect() || print "Failed to disconnect: $is->{error}";
	sleep(30);
    }
}

sub getStation {
    my($sth_add,$sth_history,$sth_supdate,$station) = @_;
    my $s_id = undef;


    # figure out how it's going into the database
    {
	lock(%station_id);
	if( ! ($s_id = $station_id{lc $station}) ) {

	    $sth_add->execute( $station );
	    $s_id = $sth_add->{mysql_insertid};
	    $station_id{lc $station} = $s_id;
	    $station_name{ lc $station } = $station;
	    print "\nnew station $station => $s_id\n";
	    $sth_history->execute( $s_id, 'new', "New station $station" );
	}
	elsif( $sth_supdate && ($station_name{ lc $station }||$station) ne $station ) {
	    $sth_supdate->execute( $station, $s_id );	
	    print "\nrenamed station $station => $s_id\n";
	    $sth_history->execute( $s_id, 'renamed', $station_name{ lc $station } . " now $station" );
	    $station_name{ lc $station } = $station;
	}
	
    }

    return $s_id;
}

sub getGlider {
    my($sth_add,$id) = @_;
    my $s_id = undef;

    return 0;

    # figure out how it's going into the database
    {
	lock(%glider_id);
	if( ! ($s_id = $glider_id{uc $id}) ) {

	    $sth_add->execute( $id );
	    $s_id = $sth_add->{mysql_insertid};
	    $glider_id{uc $id} = $s_id;
	    print "\nnew glider $id => $s_id\n";
	}
    }

    return $s_id;
}

    
sub handleAvailablity {

    my $db = DBI->connect( $db_dsn, $db_username, $db_password );
    if( ! $db ) {
	die "database problem". $DBI::errstr;
    }
    $db->do( 'SET time_zone = "GMT"' );
    
    my $sth_sids = $db->prepare( 'select station, id from stations' ); $sth_sids->execute();
    my $sth_gids = $db->prepare( 'select glider_id, callsign from gliders' ); $sth_gids->execute();
    my $sth = $db->prepare( 'insert into availability values ( ?, ?, ? ) on duplicate key update time = values(time), status = values(status)' );
    my $sth_active = $db->prepare( 'update stations set active="Y" where id = ? and active="N"' );
    my $sth_log = $db->prepare( 'insert into availability_log values ( ?, ?, ? )' );
    my $sth_first = $db->prepare( 'select s.station, time from stations s, availability a where s.id = a.station_id and a.status = "U"' ); $sth_first->execute();
    my $sth_addstation = $db->prepare( 'insert into stations ( station ) values ( ? )' );
    my $sth_updatestation = $db->prepare( 'update stations set station = ? where id = ?' );
    my $sth_history =  $db->prepare( 'insert into history values ( now(), ?, ?, ? )' );
    my $sth_timestamp = $db->prepare( 'SELECT concat(Date(now())," ",SEC_TO_TIME((TIME_TO_SEC(now()) DIV 300) * 300)) AS round_time' );
    my $sth_stats =  $db->prepare( 'insert into stats values ( ?, ?, ?, ?, ?, ?, ?, ? )' );
    my $sth_statssummary =  $db->prepare( 'insert into statssummary values ( ?, ?, ?, ?, ?, ?, ?, ? ) on duplicate key update positions=values(positions),gliders=values(gliders),crc=values(crc),ignoredpositions=values(ignoredpositions),cpu=values(cpu),temp=values(temp),time=values(time)' );

    my %station_previous_check = ();
    my %station_up = ();
    my %station_current = ();
    
    # lookup all the stations so they are available
    my $t = $sth_sids->fetchall_hashref('station');
    foreach my $station ( keys %{$t} ) {
	$station_id{lc $station} = $t->{$station}->{id};
	$station_name{lc $station} = $station;
    }

    $t = $sth_gids->fetchall_hashref('callsign');
    foreach my $callsign ( keys %{$t} ) {
	$glider_id{uc $callsign} = $t->{$callsign}->{glider_id};
    }

    $t = $sth_first->fetchall_hashref('station');
    foreach my $station ( keys %{$t} ) {
	$station_previous_check{$station} = $t->{$station}->{time};
    }

    # tell all the threads they can start
    $ready_semaphore->up(100);

    my $statscounter = 0;

    while(1) {
	# only process every 5 minutes
	sleep(600);

	# get our timestamp, use db time
	$sth_timestamp->execute();
	my ($timestamp) = $sth_timestamp->fetchrow_array();

	# copy and reset so we don't keep locked for long
	my %station_packets;
	{
	    lock( %stations_last );
	    %station_current = %stations_last;
	    %station_packets = %stations_packets;
	    %stations_last = ();
	    %stations_packets = ();
	}

	if(0)
	{
	    lock( %gliders );
	    foreach my $g ( keys %gliders ) {
		if( scalar( keys %{$gliders{$g}} ) > 1 ) {
		    print "$g:" . Dumper( $gliders{$g} ) . "\n";
		}
	    }
	    %gliders = ();
	}


	# if we are reporting stats then we need to run through all the gliders accumulated
	# do this every second scan
	my %pstats;
	{
	    lock( %stations_last );
	    foreach my $station ( values %stats ) {
		my $positions = 0; my $gliders = 0;
		foreach my $glider (values %{$station->{gliders}}) {
		    $positions += $glider;
		    $gliders++;
		}
#		if( $positions > 0 ) {
#		    print ":".$station->{station}."> $positions pos, $gliders gliders, ".($gliders ? (int(($positions||0)*10/$gliders)/10):0)."\n";
#		}
		$pstats{$station->{station}} = { gliders => $gliders, positions => $positions, station => $station->{station}, crc => $station->{crc},
						 cpu => ($station->{cpu}||0), temp => ($station->{temp}||0) };
	    }
	    %stats = ();
	}
	
	# add up how many contacts each glider had
	foreach my $station( values %pstats ) {
	    $sth_stats->execute(  $timestamp, $station->{station}, $station->{positions}, $station->{gliders}, $station->{crc}, 0, int(($station->{cpu}||0)*10), int($station->{temp}) );
	    $sth_statssummary->execute(  $station->{station}, $timestamp, $station->{positions}, $station->{gliders}, $station->{crc}, 0, int(($station->{cpu}||0)*10), int($station->{temp}) );
	}

	my $now = time();
	
	print "\nup: ";
	my @missing;
	foreach my $station ( sort keys %station_current ) {
	    my $last = $station_current{$station};
	    my $s_id = getStation( $sth_addstation, $sth_history, undef, $station );

	    print "$station [". ($station_packets{$station}||0)."]";
	    # if we didn't have a previous status it's a new station
	    if( ! ($station_previous_check{$station}||0) ) {
		$sth_log->execute( $s_id, $last, 'U' );
		push( @missing, $station );
		print " (logged UP)";
	    }
	    print ",";

	    $sth->execute( $s_id, $last, 'U' );
	    $sth_active->execute( $s_id );
	}

	print "done.\ndown: ";
	foreach my $station ( sort keys %station_previous_check ) {
	    my $last = $station_current{$station}||0;
	    my $s_id = getStation( $sth_addstation, $sth_history, undef, $station );


	    # if it hasn't had a new time then we are down, 
	    # possibly once or possibly multiple times
	    if( ! $last ) {
		print "$station";
		if( $station_previous_check{$station} ) {
		    $sth->execute( $s_id, $now, 'D' );
		    $sth_log->execute( $s_id, $now, 'D' );
		    print "  (logged down)";
		}
		print ",";
	    }

	    $station_previous_check{$station} = $last;
	}
	print "\n";
	
	foreach my $station (@missing) {
	    $station_previous_check{$station} = $station_current{$station};
	}
    }
}

sub date {
    my @t = gmtime($_[0]);
    return sprintf( "%04d-%02d-%02d", ($t[5]+1900),($t[4]+1),$t[3]);
}

sub datet {
    my @t = gmtime($_[0]);
    return sprintf( "%04d-%02d-%02dT%02d:%02d:%02d", ($t[5]+1900),($t[4]+1),$t[3],$t[2],$2[1],$t[0]);
}


sub processStationLocationBeacon {
    my ($db,$callsign,$s_id,$lt,$lg,$altitude,$comment) = @_;

    my $st_station_loc = $db->prepare( 'insert into stationlocation (time,station,lt,lg,height,country) values ( left(now(),10), ?, ?, ?, ?, ? ) on duplicate key update lt = values(lt), lg = values(lg), country=values(country)' );
    
    lock( %stations_loc );
    if( ($stations_loc{$callsign}||'') ne "$lt/$lg" ) {
	my $c = '';#getCountry($lt,$lg)
	$st_station_loc->execute( $s_id, $lt, $lg, $altitude, $c );
	print "station $callsign location update to $lt, $lg ($c)\n";
	$stations_loc{$callsign} = "$lt/$lg";
    }
}

sub processStationDetailsBeacon {
    my ($db,$callsign,$s_id,$comment) = @_;

    my $st_station_ver = $db->prepare( 'insert into stationlocation (time, station, version) values ( left(now(),10), ?,? ) on duplicate key update version=values(version)' );

    # qAC seems to be the beacons
    my $cpu = undef; my $ppm = 0; my $dbadj = 0; my $temp = -273;
    my $version = '?';
    
    if( $comment =~ /v([0-9.]+[A-Z0-9a-z-]*)/ ) {
	$version = $1;
    }
    
    if( $comment =~ /CPU:([0-9.]+) / ) {
	$cpu = $1+0;
    }

    if( $comment =~ / ([0-9.]+C|) / ) {
	$temp = ($1||0)+0;
    }
    
    if( $comment =~ /RF:.[0-9]+(.[0-9.]+)ppm.(.[0-9.]+)dB/ ) {
	$ppm = $1+0;
	$dbadj = $2+0;
    }
    
    if( ! $version ) {
	print "****** [!version] $callsign: ".($comment||'')."\n";
    }
    
    {	
	lock( %stations_ver );
	if( ($stations_ver{$callsign}||'') ne "$version" ) {
	    $st_station_ver->execute( $s_id, $version );
	    print "station $callsign version update to ($version)\n";
	    $stations_ver{$callsign} = "$version";
	}
    }
    
    printf (":: %20s: ppm %0.1f/%0.1f db [%-70s]\n", $callsign,($ppm||-99),($dbadj||-99),$comment);
    
    if( defined($ppm) && defined($dbadj) )
    {
	lock( %stations_last );

	# statistics object
	my $statsobject = $stats{$s_id};
	if( ! defined($statsobject)) {
	    $statsobject = $stats{$s_id} = shared_clone( { station => $s_id, 
							   crc => 0,
							   gliders => shared_clone( { } ),
							   cpu => 0, 
							   temp => -273 } );
	}
	$statsobject->{cpu} = $cpu;
	$statsobject->{temp} = $temp;
	
	if( ! $ppm && ! $dbadj ) {
	    if( $cpu < 0.1 ) {
		$stations_ppm{$callsign} ++;
		print "$callsign: LOWCPU & noppm (flagged $stations_ppm{$callsign} times)". $comment.">>cpu $cpu $ppm ppm, $dbadj db \n";
		
		if( $stations_ppm{$callsign} > 10 ) { 
		    $stations_status{$callsign} = 'N';
#		    $sth_history->execute( getStation( $sth_addstation, $sth_history, $sth_updatestation, $callsign ), 
#					   'noppm', "Station $callsign has low CPU and NOPPM adjustment" );
		}
	    }
	}
	else {
	    $stations_ppm{$callsign} = 0;
	    $stations_last{$callsign} = time();
	    $stations_status{$callsign} = 'U';
	}
    }
}


