use strict;
use warnings;
use English qw(-no_match_vars);
use FindBin qw($Bin);
use lib "$Bin/mock_libs";
use Apache2::RequestRec;          # from mocks
use Crypt::CBC;                   # from mocks
use Digest::MD5 qw( md5_hex );    # from mocks
use Data::Dumper;

use Test::More tests => 43;

use constant CLASS_UNDER_TEST => 'Apache2::AuthCookieDBI';
use constant EMPTY_STRING     => q{};
use constant TRUE             => 1;

use_ok(CLASS_UNDER_TEST);
test_check_password();
test_defined_or_empty();
test_decrypt_session_key();
test_encrypt_session_key();
test_dir_config_var();
test_authen_ses_key();
test_get_cipher_for_type();
test__dbi_connect();
test_get_crypted_password();
test_user_is_active();

exit;

sub set_up {
    my $auth_name   = shift;
    my $mock_config = shift || _mock_config_for_auth_name($auth_name);
    my $r           = Apache2::RequestRec->new(
        auth_name   => $auth_name,
        mock_config => $mock_config
    );    # from mock_libs
    return $r;
}

sub _mock_config_for_auth_name {
    my ($auth_name) = @_;
    my %mock_config = (
        "${auth_name}DBI_DSN"             => 'test_DBI_DSN',
        "${auth_name}DBI_User"            => 'test_DBI_User',
        "${auth_name}DBI_Password"        => 'test_DBI_Password',
        "${auth_name}DBI_SecretKey"       => 'test_DBI_SecretKey',
        "${auth_name}DBI_PasswordField"   => 'test_DBI_PasswordField',
        "${auth_name}DBI_UsersTable"      => 'test_DBI_Userstable',
        "${auth_name}DBI_UserField"       => 'test_DBI_UserField',
        "${auth_name}DBI_UserActiveField" => EMPTY_STRING,
    );
    return \%mock_config;
}

sub test_authen_ses_key {
    my $auth_name   = 'testing_authen_ses_key';
    my $secret_key  = 'test secret key';
    my $mock_config = {
        $auth_name . 'DBI_DSN'             => 'test DSN',
        $auth_name . 'DBI_SecretKey'       => $secret_key,
        $auth_name . 'DBI_User'            => $auth_name,
        $auth_name . 'DBI_Password'        => 'test DBI password',
        $auth_name . 'DBI_UsersTable'      => 'users',
        $auth_name . 'DBI_UserField'       => 'user',
        $auth_name . 'DBI_passwordfield'   => 'password',
        $auth_name . 'DBI_crypttype'       => 'none',
        $auth_name . 'DBI_groupstable'     => 'groups',
        $auth_name . 'DBI_groupfield'      => 'grp',
        $auth_name . 'DBI_groupuserfield'  => 'user',
        $auth_name . 'DBI_encryptiontype'  => 'none',
        $auth_name . 'DBI_sessionlifetime' => '00-24-00-00',
        $auth_name . 'DBI_sessionmodule'   => 'none',
    };
    my $r                  = set_up( $auth_name, $mock_config );
    my $expected_user      = 'expected_username';
    my $issue_time         = '2006-02-04-10-34-23';
    my $expire_time        = '9999-02-04-10-45-00';
    my $session_id         = 'test_session_id';
    my $extra_session_info = 'extra:info';
    my $hashed_string = 'bad-key-stored-in-ticket';   # not a 32 char hex string
    my $encrypted_session_key = join( q{:},
        $expected_user, $issue_time, $expire_time,
        $session_id,    $hashed_string );

    CLASS_UNDER_TEST->authen_ses_key( $r, $encrypted_session_key );
    like(
        $r->log_error->[-1],
        qr/ bad \s encrypted \s session_key /xm,
        'authen_ses_key() on bad encrypted key'
    );

    $r = set_up( $auth_name, $mock_config );

    my $seperator   = q{:};
    my $public_part = join( $seperator,
        $expected_user, $issue_time, $expire_time,
        $session_id,    $extra_session_info );

    my $plaintext_key = join( $seperator, $public_part, $secret_key );

    my $md5_hash = md5_hex($plaintext_key);

    $hashed_string = md5_hex( join( $seperator, $secret_key, $md5_hash ) );

    $encrypted_session_key = join( q{:}, $public_part, $hashed_string );

    my $got_user
        = CLASS_UNDER_TEST->authen_ses_key( $r, $encrypted_session_key );
    is( $got_user, $expected_user, 'authen_ses_key() on plaintext key' )
        || diag join( "\n", @{ $r->log_error() } );
    return TRUE;
}

sub test_check_password {
    Test::More::ok(
        !CLASS_UNDER_TEST->_check_password( 'foo', undef, 'bar' ),
        '_check_password() return false when password is undef'
    );
    return TRUE;
}

sub test_dir_config_var {
    my $auth_name       = 'testing_dir_config_var';
    my $variable_wanted = 'Arbitrary_Variable_Name';
    my $config_key      = $auth_name . $variable_wanted;
    my $mock_config
        = { $config_key => 'Value for this configuration variable.', };
    my $r = set_up( $auth_name, $mock_config );

    is( CLASS_UNDER_TEST->_dir_config_var( $r, $variable_wanted ),
        $mock_config->{$config_key},
        '_dir_config_var() passes correct args to $r->dir_config()'
    );
    return TRUE;
}

sub test_decrypt_session_key {
    my $auth_name = 'testing_decrypt_session_key';

    my $r = set_up($auth_name);

    my %encryption_types = (
        none        => {},
        des         => {},
        idea        => {},
        blowfish    => {},
        blowfish_pp => {},
    );

    my $secret_key  = $r->{'mock_config'}->{"${auth_name}DBI_SecretKey"};
    my $session_key = 'mock_session_key';
    foreach my $encryption_type ( sort keys %encryption_types ) {
        my @args = ( $session_key, $secret_key, $auth_name, $encryption_type );
        my $encrypted_key = CLASS_UNDER_TEST->_encrypt_session_key(@args);

 #Test::More::diag("Encryption type: '$encryption_type' key: '$encrypted_key'");

        my $decrypted_key
            = CLASS_UNDER_TEST->decrypt_session_key( $r, $encryption_type,
            $encrypted_key, $secret_key );
        Test::More::ok( defined $decrypted_key,
            "Got decrypted key for '$encryption_type'" )
            || Test::More::diag( join "\n", @{ $r->log_error() } );
        $r->{'_error_messages'} = [];

    }

}

sub test_defined_or_empty {
    my $user = 'matisse';
    my $password;    # undef
    my @other_stuff = qw( a b c );
    my @args = ( $user, $password, @other_stuff );
    my $expected = scalar @args + 1;    # Add 1 for the class argument
    is( CLASS_UNDER_TEST->_defined_or_empty( $user, $password, @other_stuff ),
        $expected, '_defined_or_empty returns expected number of items.' );
    return TRUE;
}

sub test_encrypt_session_key {
    my $session_key = 'mock_session_key';
    my $secret_key  = 'mock secret key';
    my $auth_name   = 'test_encrypt_session_key';
    my $expected    = {
        none        => $session_key,
        des         => "DES:$secret_key:$session_key",
        idea        => "IDEA:$secret_key:$session_key",
        blowfish    => "Blowfish:$secret_key:$session_key",
        blowfish_pp => "Blowfish_PP:$secret_key:$session_key",
    };

    # These tests will use a fake version of Crypt::CBC -- see set_up()
    # We are just testing that the expecyed methods got called with the
    # expected parameters. Basically we arre using the mock CBC object as
    # a "sensor" object. Look in t/mock_libs/ to see the mock object code.
    #
    foreach my $encryption_type ( sort keys %{$expected} ) {
        my @args = ( $session_key, $secret_key, $auth_name, $encryption_type );
        my $mock_crypt_text = CLASS_UNDER_TEST->_encrypt_session_key(@args);
        my $un_hexified     = $mock_crypt_text;
        if ( $encryption_type ne 'none' ) {
            $un_hexified = pack 'H*', $mock_crypt_text;
        }

        is( $un_hexified, $expected->{$encryption_type},
            "_encrypt_session_key() using '$encryption_type' (returned '$mock_crypt_text')"
        );
    }
    return TRUE;
}

sub test_get_cipher_for_type {

    # ( $dbi_encryption_type, $auth_name, $secret_key )
    my $auth_name  = 'Sample Auth Name';
    my $secret_key = 'Sample Secret Key String';
    my @test_cases = (
        {   dbi_encryption_type  => 'des',
            expected_cipher_type => 'DES',
        },
        {   dbi_encryption_type  => 'idea',
            expected_cipher_type => 'IDEA',
        },
        {   dbi_encryption_type  => 'blowfish',
            expected_cipher_type => 'Blowfish',
        },
        {   dbi_encryption_type  => 'blowfish_pp',
            expected_cipher_type => 'Blowfish_PP',
        },
        {   dbi_encryption_type  => 'BLOWFISH_PP',    # verify case-insensitive
            expected_cipher_type => 'Blowfish_PP',
        },
    );
    foreach my $case (@test_cases) {
        my $dbi_encryption_type = $case->{'dbi_encryption_type'};
        my $mock_cbc
            = CLASS_UNDER_TEST->_get_cipher_for_type( $dbi_encryption_type,
            $auth_name, $secret_key, );
        Test::More::is( $mock_cbc->{'-key'}, $secret_key,
            "_get_cipher_for_type() for $dbi_encryption_type - secret_key" );

        my $expected_cipher_type = $case->{'expected_cipher_type'};
        Test::More::is( $mock_cbc->{'-cipher'},
            $expected_cipher_type,
            "_get_cipher_for_type() for $dbi_encryption_type - cipher_type" );

        my $second_mock_from_same_args
            = CLASS_UNDER_TEST->_get_cipher_for_type( $dbi_encryption_type,
            $auth_name, $secret_key, );

        Test::More::is( $second_mock_from_same_args, $mock_cbc,
            "_get_cipher_for_type($dbi_encryption_type,$auth_name, $secret_key) cached CBC object"
        );
    }

    my $unsupported_type = 'BunnyRabbits';
    eval {
        CLASS_UNDER_TEST->_get_cipher_for_type( $unsupported_type, $auth_name,
            $secret_key, );
    };
    Test::More::like(
        $EVAL_ERROR,
        qr/Unsupported encryption type: '$unsupported_type'/,
        '_get_cipher_for_type() throws exception on unsupported encryption type.'
    );
    return TRUE;
}

sub test_get_crypted_password {
    my $auth_name         = 'test_get_crypted_password';
    my $user              = 'test_user';
    my $r                 = set_up($auth_name);
    my $expected_password = 'mock_crypted_password';
    my $got_password;
    {
        no warnings qw(once redefine);
        local *DBI::Mock::sth::fetchrow_array = sub {
            return ($expected_password);
        };
        $got_password = CLASS_UNDER_TEST->_get_crypted_password( $r, $user );
    }

    Test::More::is( $got_password, $expected_password,
        '_get_crypted_password() with default config.' );

    # Simulate password not found
    {
        no warnings qw(once redefine);
        local *DBI::Mock::sth::fetchrow_array = sub {
            return ()    # empty array, password not found;
        };
        $got_password = CLASS_UNDER_TEST->_get_crypted_password( $r, $user );
    }
    Test::More::ok( !$got_password,
        '_get_crypted_password() with password not found' );
    my $got_errrors = $r->log_error();    # from the mock request object
    Test::More::is( scalar @$got_errrors,
        1, '_get_crypted_password() logs password not found' );
    Test::More::like(
        $got_errrors->[0],
        qr/\ACould not select password/,
        '_get_crypted_password() error message for password not found'
    );

    return TRUE;
}

sub test__dbi_connect {
    my $auth_name = 'testing__dbi_connect';

    my $r           = set_up($auth_name);
    my $mock_config = $r->{'mock_config'};

    my $mock_dbh = CLASS_UNDER_TEST->_dbi_connect($r);
    my $expected = [
        $mock_config->{"${auth_name}DBI_DSN"},
        $mock_config->{"${auth_name}DBI_User"},
        $mock_config->{"${auth_name}DBI_Password"}
    ];
    Test::More::is_deeply( $mock_dbh->{'connect_cached_args'},
        $expected,
        '_dbi_connect() calls connect_cached() with expected arguments.' )
        || Test::More::diag( 'Sensor object contains: ',
        Data::Dumper::Dumper($mock_dbh) );

    Test::More::is_deeply( $r->{'_error_messages'},
        [], '_dbi_connect() - no unexpected errors.' );

    my @expected_errors = (
        qq{connect to test_DBI_DSN for auth realm $auth_name},
        q{_dbi_connect called in main::test__dbi_connect},
    );
    {
        no warnings qw(once);
        local $DBI::CONNECT_CACHED_FORCE_FAIL = 1;
        CLASS_UNDER_TEST->_dbi_connect($r);
    }
    my @got_errors   = @{ $r->{'_error_messages'} };
    my $got_failures = 0;
    for ( my $i = 0; $i <= $#expected_errors; $i++ ) {
        my $got            = $got_errors[$i];
        my $expected_regex = qr/$expected_errors[$i]/;
        Test::More::like( $got, $expected_regex,
            qq{_dbi_connect() logs error for "$expected_errors[$i]"} )
            || $got_failures++;
    }

    if ($got_failures) {
        Test::More::diag( 'Mock request object contains: ',
            Data::Dumper::Dumper($r) );
    }
    return TRUE;
}

sub test_user_is_active {
    my $auth_name = 'test_user_is_active';
    my $r         = set_up($auth_name);
    my $user      = 'TestUser';

    # The default config has an empty string for DBI_UserActiveField
    my $is_active = CLASS_UNDER_TEST->user_is_active( $r, $user );
    Test::More::ok( $is_active, 'test_user_is_active() for default config' );

    # Now set DBI_UserActiveField so that user status is determined by
    # a call to the database (we'll intercept here using mocks.)
    $r->{'mock_config'}->{"${auth_name}DBI_UserActiveField"} = 'active';
    my $not_active;

    # Simulate a user the database says is not active.
    {
        no warnings qw(once redefine);
        local *DBI::Mock::sth::fetchrow_array = sub {
            return;    # simulates user is not active
        };
        $not_active = CLASS_UNDER_TEST->user_is_active( $r, $user );
    }
    Test::More::ok( !$not_active,
        'test_user_is_active() inactive user using DBI_UserActiveField' )
        || Test::More::diag("Expected a non-true value, got '$not_active'");

    # Now simulate an active user whose status is fetch from the database
    my $active_user;
    {
        no warnings qw(once redefine);
        local *DBI::Mock::sth::fetchrow_array = sub {
            return 'yes';    # simulates an active user
        };
        $active_user = CLASS_UNDER_TEST->user_is_active( $r, $user );
    }
    Test::More::ok( $active_user,
        'test_user_is_active() with active user using DBI_UserActiveField' );

    return TRUE;
}