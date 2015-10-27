use strict;
use warnings;

use RT::Test tests => undef;

my $general = RT::Test->load_or_create_queue( Name => 'General' );
my $inbox = RT::Test->load_or_create_queue( Name => 'Inbox' );
my $specs = RT::Test->load_or_create_queue( Name => 'Specs' );
my $development = RT::Test->load_or_create_queue( Name => 'Development' );

my $engineer = RT::CustomRole->new(RT->SystemUser);
my $sales = RT::CustomRole->new(RT->SystemUser);
my $unapplied = RT::CustomRole->new(RT->SystemUser);

my $linus = RT::Test->load_or_create_user( EmailAddress => 'linus@example.com' );
my $blake = RT::Test->load_or_create_user( EmailAddress => 'blake@example.com' );
my $williamson = RT::Test->load_or_create_user( EmailAddress => 'williamson@example.com' );
my $moss = RT::Test->load_or_create_user( EmailAddress => 'moss@example.com' );
my $ricky = RT::Test->load_or_create_user( EmailAddress => 'ricky.roma@example.com' );


diag 'setup' if $ENV{'TEST_VERBOSE'};
{
    ok( RT::Test->add_rights( { Principal => 'Privileged', Right => [ qw(CreateTicket ShowTicket ModifyTicket OwnTicket SeeQueue) ] } ));

    my ($ok, $msg) = $engineer->Create(
        Name      => 'Engineer-' . $$,
        MaxValues => 1,
    );
    ok($ok, "created Engineer role: $msg");

    ($ok, $msg) = $sales->Create(
        Name      => 'Sales-' . $$,
        MaxValues => 0,
    );
    ok($ok, "created Sales role: $msg");

    ($ok, $msg) = $unapplied->Create(
        Name      => 'Unapplied-' . $$,
        MaxValues => 0,
    );
    ok($ok, "created Unapplied role: $msg");

    ($ok, $msg) = $sales->AddToObject($inbox->id);
    ok($ok, "added Sales to Inbox: $msg");

    ($ok, $msg) = $sales->AddToObject($specs->id);
    ok($ok, "added Sales to Specs: $msg");

    ($ok, $msg) = $engineer->AddToObject($specs->id);
    ok($ok, "added Engineer to Specs: $msg");

    ($ok, $msg) = $engineer->AddToObject($development->id);
    ok($ok, "added Engineer to Development: $msg");
}

diag 'create tickets in General (no custom roles)' if $ENV{'TEST_VERBOSE'};
{
    my $general1 = RT::Test->create_ticket(
        Queue     => $general,
        Subject   => 'a ticket',
        Owner     => $williamson,
        Requestor => [$blake->EmailAddress],
    );
    is($general1->OwnerObj->id, $williamson->id, 'owner is correct');
    is($general1->RequestorAddresses, $blake->EmailAddress, 'requestors correct');
    is($general1->CcAddresses, '', 'no ccs');
    is($general1->AdminCcAddresses, '', 'no adminccs');
    is($general1->RoleAddresses($engineer->GroupType), '', 'no engineer (role not applied to queue)');
    is($general1->RoleAddresses($sales->GroupType), '', 'no sales (role not applied to queue)');

    my $general2 = RT::Test->create_ticket(
        Queue     => $general,
        Subject   => 'another ticket',
        Owner     => $linus,
        Requestor => [$moss->EmailAddress, $williamson->EmailAddress],
        Cc        => [$ricky->EmailAddress],
        AdminCc   => [$blake->EmailAddress],
    );
    is($general2->OwnerObj->id, $linus->id, 'owner is correct');
    is($general2->RequestorAddresses, (join ', ', $moss->EmailAddress, $williamson->EmailAddress), 'requestors correct');
    is($general2->CcAddresses, $ricky->EmailAddress, 'cc correct');
    is($general2->AdminCcAddresses, $blake->EmailAddress, 'admincc correct');
    is($general2->RoleAddresses($engineer->GroupType), '', 'no engineer (role not applied to queue)');
    is($general2->RoleAddresses($sales->GroupType), '', 'no sales (role not applied to queue)');

    my $general3 = RT::Test->create_ticket(
        Queue                => $general,
        Subject              => 'oops',
        Owner                => $ricky,
        $engineer->GroupType => $linus,
        $sales->GroupType    => [$blake->EmailAddress],
    );
    is($general3->OwnerObj->id, $ricky->id, 'owner is correct');
    is($general3->RequestorAddresses, '', 'no requestors');
    is($general3->CcAddresses, '', 'no cc');
    is($general3->AdminCcAddresses, '', 'no admincc');
    is($general3->RoleAddresses($engineer->GroupType), '', 'no engineer (role not applied to queue)');
    is($general3->RoleAddresses($sales->GroupType), '', 'no sales (role not applied to queue)');
}

diag 'create tickets in Inbox (sales role)' if $ENV{'TEST_VERBOSE'};
{
    my $inbox1 = RT::Test->create_ticket(
        Queue     => $inbox,
        Subject   => 'a ticket',
        Owner     => $williamson,
        Requestor => [$blake->EmailAddress],
    );
    is($inbox1->OwnerObj->id, $williamson->id, 'owner is correct');
    is($inbox1->RequestorAddresses, $blake->EmailAddress, 'requestors correct');
    is($inbox1->CcAddresses, '', 'no ccs');
    is($inbox1->AdminCcAddresses, '', 'no adminccs');
    is($inbox1->RoleAddresses($engineer->GroupType), '', 'no engineer (role not applied to queue)');
    is($inbox1->RoleAddresses($sales->GroupType), '', 'no sales (role not applied to queue)');

    my $inbox2 = RT::Test->create_ticket(
        Queue     => $inbox,
        Subject   => 'another ticket',
        Owner     => $linus,
        Requestor => [$moss->EmailAddress, $williamson->EmailAddress],
        Cc        => [$ricky->EmailAddress],
        AdminCc   => [$blake->EmailAddress],
    );
    is($inbox2->OwnerObj->id, $linus->id, 'owner is correct');
    is($inbox2->RequestorAddresses, (join ', ', $moss->EmailAddress, $williamson->EmailAddress), 'requestors correct');
    is($inbox2->CcAddresses, $ricky->EmailAddress, 'cc correct');
    is($inbox2->AdminCcAddresses, $blake->EmailAddress, 'admincc correct');
    is($inbox2->RoleAddresses($engineer->GroupType), '', 'no engineer (role not applied to queue)');
    is($inbox2->RoleAddresses($sales->GroupType), '', 'no sales (role not applied to queue)');

    my $inbox3 = RT::Test->create_ticket(
        Queue                => $inbox,
        Subject              => 'oops',
        Owner                => $ricky,
        $engineer->GroupType => $linus,
        $sales->GroupType    => [$blake->EmailAddress],
    );
    is($inbox3->OwnerObj->id, $ricky->id, 'owner is correct');
    is($inbox3->RequestorAddresses, '', 'no requestors');
    is($inbox3->CcAddresses, '', 'no cc');
    is($inbox3->AdminCcAddresses, '', 'no admincc');
    is($inbox3->RoleAddresses($engineer->GroupType), '', 'no engineer (role not applied to queue)');
    is($inbox3->RoleAddresses($sales->GroupType), $blake->EmailAddress, 'got sales');
}

done_testing;

