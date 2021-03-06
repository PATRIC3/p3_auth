package P3TokenValidator;

use Data::Dumper;
use LWP::UserAgent;
use strict;
use JSON::XS;
use Crypt::OpenSSL::RSA;
use P3AuthConstants ':all';

sub new
{
    my($class) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);

    my $self = {
	ua => $ua,
	pubkey_cache => {},
	cache_lifetime => 10,
	token_signers => { map { $_ => 1 } trust_token_signers },
    };
    return bless $self, $class;
}

sub validate
{
    my($self, $token) = @_;

    my $token_str = ref($token) ? $token->token() : $token;
    
    my($sig_data) = $token_str =~ /^(.*)\|sig=/;

    if (!$sig_data)
    {
	return wantarray ? (undef, "Missing signature data") : undef;
    }

    my %vars = map { split /=/ } split /\|/, $token->token();
    
    if (time >= $vars{expiry})
    {
	return wantarray ? (undef, "Token expired") : undef;
    }
    
    my $signer = $vars{SigningSubject};
    unless ($self->{token_signers}->{$signer})
    {
	return wantarray ? (undef, "Token signed by unknown signer $signer") : undef;
    }

    my $pubkey = $self->get_pubkey($signer);
    unless($pubkey)
    {
	return wantarray ? (undef, "Could not retrieve signer pubkey for $signer") : undef;
    }
    
    my $binary_sig = pack('H*',$vars{'sig'});

    my $verify = $pubkey->verify($sig_data, $binary_sig);
    if (!$verify)
    {
	return wantarray ? (undef, "Token signature did not verify") : undef;
    }

    return wantarray ? ($verify, "") : $verify;
}

sub get_pubkey
{
    my($self, $url) = @_;

    my $ent = $self->{pubkey_cache}->{$url};
    if ($ent && time < $ent->{expires})
    {
	return $ent->{pubkey};
    }

    my $res = $self->{ua}->get($url);

    if (!$res->is_success)
    {
	warn "Cannot retrieve public key at $url: " . $res->status_line;
	return undef;
    }

    my $data = decode_json($res->content);

    return undef unless $data->{valid};
    my $pubkey_txt = $data->{pubkey};

    return undef unless $pubkey_txt;

    my $pubkey = Crypt::OpenSSL::RSA->new_public_key($pubkey_txt);

    if (!$pubkey)
    {
	warn "Cannot create pubkey from $pubkey\n";
	return undef;
    }
    $pubkey->use_sha1_hash();

    $self->{pubkey_hash}->{$url} = { expires => (time + $self->{cache_lifetime}),
				     pubkey => $pubkey };
    return $pubkey;
}

1;
