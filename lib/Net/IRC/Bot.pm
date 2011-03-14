use v6;
use Net::IRC::Connection;
use Net::IRC::DefaultHandlers;
use Net::IRC::Event;

class Net::IRC::Bot {
	has $conn is rw;

	#Set some sensible defaults for the bot.
	#These are not stored as state, they are just used for the bot's "start state"
	#Changing things like $nick and @channels are tracked in %state
	has $nick     = "Rakudobot";
	has @altnicks = $nick X~ ("_","__",^10);
	has $username = "Clunky";
	has $realname = '$@%# yeah, perl 6!';

	has $server   = "irc.perl.org";
	has $port     = 6667;
	has $password;
	
	has @channels = [];
	
		#Most important part of the bot.
	has @modules;
	#Options
	has $debug = False;

	#State variables.
	has %state;

	submethod BUILD {
		callsame;
		@modules.push(Net::IRC::DefaultHandlers.new);
	}

	method !resetstate() {
		%state = (
			nick         => $nick,
			altnicks     => @altnicks,
			autojoin     => @channels,
			channels     => %(),
			loggedin     => False,
			connected    => False,
		)
	}

	method !connect(){
		#Establish connection to server
		self!resetstate;
		say "Connecting to $server on port $port";
		$conn = Net::IRC::Connection.new(peeraddr => $server, peerport => $port);

		#Send PASS if needed
		$conn.sendln("PASS $password") if $password;

		#Send NICK & USER.
		#If the nick collides, we'll resend a new one when we recieve the error later.
		#USER Parameters: 	<username> <hostname> <servername> <realname>
		$conn.sendln("NICK $nick");
		$conn.sendln("USER $username abc.xyz.net $server :$realname");
		%state<connected> = True;
	}

	method !disconnect($quitmsg = "Leaving"){
		if %state<connected> {
			$conn.sendln("QUIT :$quitmsg");
			$conn.close;
		}
	}

	grammar RawEvent {
		token TOP {
			^ 
			[':' [<user>|<server=host>] <.space> || <?>] 
			<command> 
			[ <.space>+ [':'$<params>=(.*)$ || $<params>=<-space>+] ]* 
			$
		}

		token user {
			$<nick>=<-[:!]>+ '!' $<ident>=<-[@]>+ '@' <host>
		}

		token host {
			#[ <-space - [. $ @ !]>+ ] ** '.'
			
			#Due to some IRC servers/services allowing anything as a host format,
			#I've decided to define a 'host' as 'anything but a space'. Bah.
			<-space>+
		}

		token command {
			<.alpha>+ | \d\d\d
		}

		token params {
			[ ':'.*$ | <-space>+ ]
		}
	}

	method run() {					
		self!disconnect;
		self!connect;
		loop {
			#XXX: Support for timed events?
			my $line = $conn.get.chomp
				or die "Connection error.";

			my $event = RawEvent.parse($line)
				or $*ERR.say("Could not parse the following IRC event: $line") and next;

			say ~$event if $debug;

			self!dispatch($event);
		}
	}

	multi method !dispatch($raw) {
		#Make an event object and fill it as much as we can.
		#XXX: Should I just use a single cached Event to save memory?
		
		my $event = Net::IRC::Event.new(
			:raw($raw),
			:command(~$raw<command>),
			:conn($conn),
			:state(%state),

			:who($raw<user> || $raw<server>),
			:where(~$raw<params>[0]),
			:what(~$raw<params>[*-1]),
		);


		# Dispatch to the raw event handlers.
		@modules>>.*"irc_{ lc $event.command }"($event);
		given uc $event.command {
			when "PRIVMSG" {
				#Check to see if its a CTCP request.
				if $event.what ~~ /^\c01 (.*) \c01$/ {
					my $text = ~$0;
					if $debug {
						say "Received CTCP $text from {$event.who}" ~
						( $event.where eq $event.who ?? '.' !! " (to channel {$event.where})." );
					}

					$text ~~ /^ (.+?) [<.ws> (.*)]? $/;
					$event.what = $1 && ~$1;
					@modules>>.*"ctcp_{ lc $0 }"($event);
					#If its a CTCP ACTION then we also call 'emoted'
					@modules>>.*emoted($event) if uc $0 eq 'ACTION';		
				}
				else {
					@modules>>.*said($event);
				}
			}

			when "NOTICE" {
				@modules>>.*noticed($event);
			}

			when "KICK" {
				$event.what = $raw<params>[1];
				@modules>>.*kicked($event);
			}

			when "JOIN" {
				@modules>>.*joined($event);
			}

			when "NICK" {
				@modules>>.*nickchange($event);
			}

			when "376"|"422" {
				#End of motd / no motd. (Usually) The last thing a server sends the client on connect.
				@modules>>.*connected($event)
			}
		}
	}
}
