# $Header$
# (c) 1996-2000 Jesse Vincent <jesse@fsck.com>
# This software is redistributable under the terms of the GNU GPL
package RT::Interface::Email; 

use RT::Ticket;
use MIME::Parser;
use Mail::Address;
use RT::User;
use RT::CurrentUser;
   
# {{{ sub activate 
sub activate  {
    my ($Verbose, $ReturnTid, $Debug);
   
    #Set some sensible defaults 
    my $Queue = 1;
    my $Action = "correspond";  
  
    while (my $flag = shift @ARGV) {
      if (($flag eq '-v') or ($flag eq '--verbose')) {
	$Verbose = 1;
      }
      if (($flag eq '-t') or ($flag eq '--ticketid')) {
	$ReturnTid = 1;
      }

      if (($flag eq '-d') or ($flag eq '--debug')) {
	$Debug = 1;
      }

      if (($flag eq '-q') or ($flag eq '--queue')) {
	$Queue = shift @ARGV;
      } 
      if (($flag eq '-a') or ($flag eq '--action')) {
	$Action = shift @ARGV;
      } 
      

  }
    
    my ($From, $TicketId, $Subject,$SquelchReplies);
    
    $RT::Logger->info("RT Mailgate started for $Queue/$Action");
    
    my $time = time;
    
    # {{{ Parse the MIME entity

    # Create a new parser object:
    
    my $parser = new MIME::Parser;
    
    # {{{ Config $parser to store large attacments in temp dir

    ## TODO: Does it make sense storing to disk at all?  After all, we
    ## need to put each msg as an in-core scalar before saving it to
    ## the database, don't we?

    ## At the same time, we should make sure that we nuke attachments 
    ## Over max size and return them

    ## TODO: Remove the temp dir when we don't need it any more.

    my $AttachmentDir = "/tmp/rt-tmp-$time-$$-".int(rand(100));
    
    #TODO log an emergency and bounce the message (MIME Encoded) 
    # to the sender and to RT-Owner  if we can't store the message
    mkdir("$AttachmentDir", 0700) || die "Couldn't create temp dir!";
    
    # Set up output directory for files:
    $parser->output_dir("$AttachmentDir");
    
    # Set up the prefix for files with auto-generated names:
    $parser->output_prefix("part");

    # If content length is <= 20000 bytes, store each msg as in-core scalar;
    # Else, write to a disk file (the default action):
  
    $parser->output_to_core(20000);

    # }}} (temporary directory)

    #Ok. now that we're set up, let's get the stdin.
    #TODO: Deal with this error better
    my $entity = $parser->read(\*STDIN) or die "couldn't parse MIME stream";
    
    #Now we've got a parsed mime object. 
        
    # Get the head, a MIME::Head:
    $head = $entity->head;
    
    # TODO - information about the charset is lost here!
    $head->decode;

    # }}}

    #Get us a current user object.
    my $CurrentUser = &GetCurrentUser($head);

    my $MessageId = $head->get('Message-Id') || "<no-message-id-".time.rand(2000)."\@.$RT::rtname>";
 
    # {{{ Lets check for mail loops of various sorts.

    my $IsAutoGenerated = &CheckForAutoGenerated($head);
    
    my $IsSuspiciousSender = &CheckForSuspiciousSender($head);

    my $IsALoop = &CheckForLoops($head);
     
    #If the message is autogenerated, we need to know, so we can not 
    # send mail to the sender
    if ($IsSuspiciousSender || $IsAutoGenerated || $IsALoop) {
	$SquelchReplies = 1;
	#TODO: Is what we want to do here really 
	#  "Make the requestor cease to get mail from RT"?
	# This might wreak havoc with vacation-mailing users.
	# Maybe have a "disabled for bouncing" state that gets
	# turned off when we get a legit incoming message

	# Tobix: I don't think we should turn off watchers, I think we
	# should only stop _this_ transaction from generating emails.
	# A "silent transaction" mode - yeah, that was also a
	# suggested feature at RTCon.  That will be enough from
	# stopping loops.  
        # TODO: I also think it's important that it's
	# clearly written in the ticket history that this is a "silent
	# transaction"
    }

    #If it's actually a _local loop_ we want to warn someone
    if ($IsALoop) {
	$RT::Logger->crit("RT Recieved mail ($MessageId) from itself");
        
	#Should we mail it to RTOwner?
	## TODO: This should be documented in config.pm
	if ($RT::LoopsToRTOwner) {
	    &MailError(To => $RT::OwnerEmail,
		       Subject => "RT Bounce: $subject",
		       Explanation => "RT thinks this message may be a bounce",
		       MIMEObj => $entity);


	    ## TODO: This return belongs to the outside of this
	    ## if-scope, and it has to be documented it in config.pm.
	    ## I think it makes sense to have it on as default, ref
	    ## [fsck #291]

	    #Do we actually want to store it?
	    return unless ($RT::StoreLoops);
	}
    }
    
    # }}}

    #Pull apart the subject line
    $Subject = $head->get('Subject') || "[no subject]";
    chomp $Subject;
    $TicketId = &GetTicketId($Subject);


    if ($SquelchReplies) {
	## TODO: This is a hack.  It should be some other way to
	## indicate that the transaction should be "silent".

	$head->add('RT-Mailing-Loop-Alarm', 'True');
    }
 
    
    if (!defined($TicketId)) {
   	
	#If the message doesn't reference a ticket #, create a new ticket
	# {{{ Create a new ticket
	if ($Action =~ /correspond/) {
	    
	    #    open a new ticket 
	    my $Ticket = new RT::Ticket($CurrentUser);
	    my ($id, $Transaction, $ErrStr) = 
	      $Ticket->Create ( Queue => $Queue,
				Area => $Area,
				Subject => $Subject,
				Requestor => $CurrentUser,
				RequestorEmail => $CurrentUser->UserObj->EmailAddress,
				MIMEObj => $entity
			      );
	}
	# }}}
	
	else {
	    #TODO Return an error message
	    $RT::Logger->crit("$Action aliases require a TicketId to work on (from ".$CurrentUser->UserObj->EmailAddress.") $MessageId");
	    return();
	}
    }
    
    else { # If we have a ticketid defined
	
	#   If the action is comment, add a comment.
	if ($Action =~ /comment/i){
	    my $Ticket = new RT::Ticket($CurrentUser);
	    $Ticket->Load($TicketId) || die "Could not load ticket";
	    #TODO: make this a scrip	
	    $Ticket->Open;	# Reopening it, if necessary 
	 
	    # TODO: better error handling
	    $Ticket->Comment(MIMEObj=>$entity);
	}
	
	#   If the message is correspondence, add it to the ticket
	elsif ($Action =~ /correspond/i) {
	    
	    my $Ticket = RT::Ticket->new($CurrentUser);
	    $Ticket->Load($TicketId);

	    $Ticket->Open;   #TODO: Don't open if it's alreadyopen
	    
	    #TODO: Check for error conditions
	    $Ticket->Correspond(MIMEObj => $entity);
	}

	elsif ($Action ne 'action') {
	    $RT::Logger->crit("$Action type unknown for $MessageId check definitions in /etc/aliases");
	}
    }
    
    
    #Parse commands in the headers or message boddy.
    &ParseCommands($entity);

    return(0);
  }
# }}}

# {{{ sub CheckForLoops 
sub CheckForLoops  {
  my $head = shift;

  #If this instance of RT sent it our, we don't want to take it in
  my $RTLoop = $head->get("X-RT-Loop-Prevention") || "";
  if ($RTLoop eq "$RT::rtname") {
      return (1);
  }

  # TODO: We might not trap the rare case where RT instance A sends a mail
  # to RT instance B which sends a mail to ...
  return (undef);
}
# }}}

# {{{ sub CheckForSuspiciousSender
sub CheckForSuspiciousSender {
    my $head = shift;
  #if it's from a postmaster or mailer daemon, it's likely a bounce.

  #TODO: better algorithms needed here - there is no standards for
  #bounces, so it's very difficult to separate them from anything
  #else.  At the other hand, the Return-To address is only ment to be
  #used as an error channel, we might want to put up a separate
  #Return-To address which is treated differently.

  #TODO: search through the whole email and find the right Ticket ID.
  my $From = $head->get("From") || "";
    
    if (($From =~ /^mailer-daemon/i) or
	($From =~ /^postmaster/i)){
	return (1);
	
    }
    
    return (undef);

}
# }}}

# {{{ sub CheckForAutoGenerated
sub CheckForAutoGenerated {
  my $head = shift;
  #If it claims to be bulk mail, be sure not to send out mail to the requestor
  
  my $Precedence = $head->get("Precedence") || "" ;
  
  if ($Precedence =~ /^(bulk|junk)/i) {
    return (1);
  }
  else {
    return (0);
  }
}
# }}}

# {{{ sub GetTicketId 

sub GetTicketId {
    my $Subject = shift;
    my ($Id);
    
    if ($Subject =~ s/\[$RT::rtname \#(\d+)\]//i) {
	$Id = $1;
	$RT::Logger->debug("Found a ticket ID. It's $Id");
	return($Id);
    }
    else {
	return(undef);
    }
}
# }}}

# {{{ sub ParseCommands

sub ParseCommands {
  my $entity = shift;

  my ($TicketId);
  # If the message contains commands, execute them
  
  # I'm allowing people to put in stuff in the mail headers here,
  # with the header key "RT-Command":
  
  my $commands=$entity->head->get('RT-Command');
  my @commands=(defined $commands ? ( ref $commands ? @$commands : $commands ) : ());
  
  # TODO: pull out "%RT " commands from the message body and put
  # them in commands
  
  # TODO: Handle all commands
  
  # TODO: The sender of the mail must be notificated about all %RT
  # commands that has been executed, as well as all %RT commands
  # that couldn't be processed.  I'll just use "die" for errors as
  # for now.
  
  for (@commands) {
      next if /^$/;
      chomp;
      $RT::Logger->info("Action requested through email: $_");
      my ($command, $arguments)=/^(?:\s*)((?:\w|-)+)(?: (.*))?$/
	  or die "syntax error ($_)";
      if ($command =~ /^(Un)?[Ll]ink$/) {
	  if ($1) {
	      warn "Unlink not implemented yet: $_";
	      next;
	  }
	  my ($from, $typ, $to)=($arguments =~ m|^(.+?)(?:\s+)(\w+)(?:\s+)(.+?)$|)
	      or die "syntax error in link command ($arguments)";
	  my $dir='F';
	  # dirty? yes. how to fix?
	  $TicketId=RT::Link::_IsLocal(undef, $from);
	  if (!$TicketId) {
	      $dir='T';
	      $TicketId=RT::Link::_IsLocal(undef, $to);
	      warn $TicketId;
	  }
	  if (!$TicketId) {
	      die "Links require a base and a target ticket";
	  }
	  my $Ticket = new RT::Ticket($CurrentUser);
	  $Ticket->Load($TicketId) || die "Could not load ticket";

	  #TODO: use a published interface.  +++
	  $Ticket->_NewLink(dir=>$dir,Target=>$to,Base=>$from,Type=>$typ);
	  $RT::Logger->info( $CurrentUser->UserId." created a link by mail ($_)");
      } else {
	  die "unknown command $command : $_";
      }
  }
}

# }}}

# {{{ sub MailError 
sub MailError {
    my %args = (To => undef,
		From =>undef,
		Subject => undef,
		Explanation => undef,
		MIMEObj => undef,
		@_);
    
    die "RT::Interface::Mail::MailError stubbed";
}

# }}}

# {{{ sub GetCurrentUser 

sub GetCurrentUser  {
  my $head = shift;

  #Figure out who's sending this message.
  my $From = $head->get('Reply-To') || $head->get('From') || $head->get('Sender');

  use Mail::Address;
  #TODO: probably, we should do something smart here like generate
  # the ticket as "system"
  
  my @FromAddresses = Mail::Address->parse($From) or die "Couldn't parse From-address";

  my $FromObj = $FromAddresses[0];



  my $Name =  ($FromObj->phrase || $FromObj->comment || $FromObj->address);
  
  #Lets take the from and load a user object.


  my $Address = $FromObj->address;

  #This will apply local address canonicalization rules
  $Address = &RT::CanonicalizeAddress($Address);

  my $CurrentUser = RT::CurrentUser->new($FromObj->address);
  
  # One more try if we couldn't find that user
  # TODO: we should never be calling _routines from external code.
  # what the hell are we doing here ++++
  $CurrentUser->Id || $CurrentUser->_Init($Name);
  
  unless ($CurrentUser->Id) {
    #If it fails, create a user
    
    my $SystemUser = new RT::CurrentUser(1);
    my $NewUser = RT::User->new($SystemUser);#Create a user as root 
    #TODO: Figure out a better way to do this
    ## Tobix: What's wrong with this way?
    my ($Val, $Message) = $NewUser->Create(UserId => $FromObj->address,
					   EmailAddress => $FromObj->address,
					   RealName => "$Name",
					   Password => undef,
					   CanManipulate => 0,
					   Comments => undef
					  );
    
    if (!$Val) {
      #TODO this should not just up and die. at the worst it should send mail.
      die $Message;
    }

    

    #Load the new user object
    $CurrentUser->Load($FromObj->address);
  }
  return ($CurrentUser);
}

# }}}

1;
