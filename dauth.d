/++

The default settings and behaviors in this module are specifically chosen
with this order of priorities:

1. Flexibility (Top Priority)
2. Overall Security
3. Reliability/Correctness of User Code
4. Cryptographic Security
5. Convenience
6. Efficiency (Lower Priority, but still important)

Rationale:

It may seem strange that "Flexibility" is #1, even ahead of security, but
that's necessary to ensure this library can be used in all potential
use-cases (for example, to interface with a legacy system that uses
a known-insecure crypto). After all, if this can't be used, it can't provide
any security at all.

DAuth does take steps to encourage good security practices, and to help
developers achieve it, but ultimately the library's user is responsible for
their own security-related choices.

Similarly, it may appear odd that "Cryptographic Security" is ranked below
"Reliability/Correctness". However, bugs can often be an even greater threat to
overall security than cryptographic weaknesses - and in unpredictable ways.

Convenience is ranked slightly above efficiency because it directly encourages
this library's actual usage, and thereby encourages security. Improved
efficiency, when needed, can always be tweaked as necessary.


Typical usage:
----------------------------------------
void setPassword(string user, string pass)
{
	string hashString = makeHash(pass).toString();
	saveUserPassword(user, hashString);
}

bool validateUser(string user, string pass)
{
	string hashString = loadUserPassword(user);
	return isPasswordCorrect(pass, parseHash(hashString));
}
----------------------------------------

The above is typical expected usage. It stores randomly-salted password hashes,
using the default hashing digest, in a forward-compatible ASCII-safe text
format.

Nearly any aspect of the authentication system can be customized, to ensure
compatibility with both existing infrastructure and future cryptographic
developments:

- Passwords can be hashed using any Phobos-compatibe digest (See std.digest.digest).
- Salts can be provided manually, or have a user-defined length.
- Hashes and salts can be stored in any way or format desired. This is because
the Hash struct returned by makeHash() and parseHash()
provides easy access to the hash, the salt, and the digest used.
- The method of combining the salt and raw password can be user-defined (via
the optional 'salter' parameter of makeHash() and isPasswordCorrect()).
- The toString supports OutputRange sinks, to avoid unnecessary allocations.
- Passwords, salts, and randomized tokens (for one-use URLs) can all be
automatically generated, optionally driven by custom Phobos-compatible
random number generators.

This is a more customized usage example:
------------------------------------------
import std.digest.md;
import std.random;

void setPassword(string user, string pass)
{
	// Note: This randomizer is not actually suitable for crypto purposes.
	static MinstdRand rand;
	auto salt = randomSalt(rand, 64);

	// Note: MD5 should never be used for real passwords.
	auto myHash = makeHash!MD5(pass, salt);
	
	saveUserInfo(user, myHash.hash, myHash.salt);
}

bool validateUser(string user, string pass)
{
	string hash = loadUserPassword(user);
	string salt = loadUserSalt(user);

	return isPasswordCorrect!MD5(pass, hash, salt);
}
------------------------------------------

For a good background on authentication, see:
https://crackstation.net/hashing-security.htm
+/

module dauth;

import std.algorithm;
import std.array;
import ascii = std.ascii;
import std.base64;
import std.conv;
import std.digest.crc;
import std.digest.md;
import std.digest.ripemd;
import std.digest.sha;
import std.exception;
import std.random;
import std.range;
import std.typecons;

/// Enable DAuth unittests:
///    -unittest -version=DAuth_AllowWeakSecurity -version=DAuth_Unittest
///
/// Enable DAuth unittests, but silence all non-error output:
///    -unittest -version=DAuth_AllowWeakSecurity -version=DAuth_Unittest -version=DAuth_Unittest_Quiet
version(DAuth_Unittest)
{
	version(DAuth_Unittest_Quiet) {} else
		version = Loud_Unittest;
	
	version(Loud_Unittest)
		import std.stdio;
	
	void unitlog(string str)
	{
		version(Loud_Unittest)
		{
			writeln("unittest DAuth: ", str);
			stdout.flush();
		}
	}
}

version(DAuth_AllowWeakSecurity) {} else
{
	version = DisallowWeakSecurity;
}

alias Salt = ubyte[];
alias Salter(TDigest) = void function(ref TDigest, Password, Salt);
alias DefaultCryptoRand = Mt19937; /// Bad choice, but I'm not sure if Phobos has a crypto-oriented random.
alias DefaultDigest = SHA1; /// Bad choice, but the best Phobos currently has.
alias DefaultDigestClass = WrapperDigest!DefaultDigest;
alias TokenBase64 = Base64Impl!('-', '_', '~');

/// In characters. Default length of randomly-generated passwords.
enum defaultPasswordLength = 20;

/++
Punctuation is not included in generated passwords by default. Technically,
this is slightly less secure for a given password length, but it prevents
syntax-related bugs when a generated password is stored in a (properly-secured)
text-based configuration file.

If you know how the generated password will be used, you can add known-safe
punctuation to this when you call randomPassword.
+/
enum defaultPasswordChars = cast(immutable(ubyte)[]) (ascii.letters ~ ascii.digits);

/// In bytes. Must be a multiple of 4.
enum defaultSaltLength = 32;

/// In bytes of randomness, not length of token.
/// Must be a multiple of 4. Although, due to usage of base64, using a multiple
/// of 12 prevents a padding tilde from existing at the end of every token.
enum defaultTokenStrength = 36;

string defaultDigestCodeOfObj(Digest digest)
{
	if     (cast( CRC32Digest     )digest) return "CRC32";
	else if(cast( MD5Digest       )digest) return "MD5";
	else if(cast( RIPEMD160Digest )digest) return "RIPEMD160";
	else if(cast( SHA1Digest      )digest) return "SHA1";
	else
		throw new UnknownDigestException("Unknown digest type");
}

Digest defaultDigestFromCode(string digestCode)
{
	switch(digestCode)
	{
	case "CRC32":     return new CRC32Digest();
	case "MD5":       return new MD5Digest();
	case "RIPEMD160": return new RIPEMD160Digest();
	case "SHA1":      return new SHA1Digest();
	default:
		throw new UnknownDigestException("Unknown digest code");
	}
}

void defaultSalter(TDigest)(ref TDigest digest, Password password, Salt salt)
	if(isAnyDigest!TDigest)
{
	digest.put(cast(immutable(ubyte)[])salt);
	digest.put(password.data);
}

/++
Note, this only checks Phobos's RNG's and digests, and only by type. This
works on a blacklist basis - it blindly accepts any Phobos-compatible RNG
or digest it does not know about. This is only supplied as a convenience. It
is always your own responsibility to select an appropriate algorithm for your
own needs.

And yes, unfortunately, this does currently rule out all RNG's and digests
currently in Phobos (as of v2.065). They are all known to be fairly weak
for password-hashing purposes, even SHA1 which despite being heavily used is
known weak against increasingly practical highly-parallel (ex: GPU) brute-force
attacks.

For random number generators, you should use a CPRNG (cryptographically secure
pseudorandom number generator):
    http://en.wikipedia.org/wiki/Cryptographically_secure_pseudo-random_number_generator

For digests, you should use an established "key stretching" algorithm
( http://en.wikipedia.org/wiki/Key_stretching#History ), intended
for password hashing. These contain deliberate inefficiencies that cannot be
optimized away even with massive parallelization (such as a GPU cluster). These
are NOT too inefficient to use for even high-traffic authentication, but they
do thwart the parallelized brute force attacks that algorithms used for
streaming data encryption, such as SHA1, are increasingly susceptible to.
    https://crackstation.net/hashing-security.htm
+/
bool isKnownWeak(T)() if(isDigest!T || isUniformRNG!T)
{
	return
		is(T == CRC32) ||
		is(T == MD5) ||
		is(T == RIPEMD160) ||
		is(T == SHA1) ||
		
		// Requires to-be-released DMD 2.066:
		//__traits(isSame, TemplateOf!T, LinearCongruentialEngine) ||
		//__traits(isSame, TemplateOf!T, MersenneTwisterEngine) ||
		//__traits(isSame, TemplateOf!T, XorshiftEngine);
		is(T == MinstdRand0) ||
		is(T == MinstdRand) ||
		is(T == Mt19937) ||
		is(T == Xorshift32) ||
		is(T == Xorshift64) ||
		is(T == Xorshift96) ||
		is(T == Xorshift128) ||
		is(T == Xorshift160) ||
		is(T == Xorshift192) ||
		is(T == Xorshift);
}

///ditto
bool isKnownWeak(T)(T digest) if(is(T : Digest))
{
	return
		cast(CRC32Digest)digest ||
		cast(MD5Digest)digest ||
		cast(RIPEMD160Digest)digest ||
		cast(SHA1Digest)digest;
}

private void validateStrength(T)() if(isDigest!T || isUniformRNG!T)
{
	version(DisallowWeakSecurity)
	{
		static if(isKnownWeak!T())
		{
			pragma(msg, "ERROR: "~T.stringof~" - "~KnownWeakException.message);
			static assert(false);
		}
	}
}

private void validateStrength(Digest digest)
{
	version(DisallowWeakSecurity)
	{
		enforce(!isKnownWeak(digest),
			new KnownWeakException(defaultDigestCodeOfObj(digest)));
	}
}

class UnknownDigestException : Exception
{
	this(string msg) { super(msg); }
}

class KnownWeakException : Exception
{
	static enum message =
		"This is known to be weak for salted password hashing. "~
		"If you understand and accept the risks, you can force DAuth "~
		"to allow it with -version=DAuth_AllowWeakSecurity";
	
	this(string algoName)
	{
		super(algoName ~ " - " ~ message);
	}
}

/// Like std.digest.digest.isDigest, but also accepts OO-style digests
/// (ie. classes deriving from interface std.digest.digest.Digest)
template isAnyDigest(TDigest)
{
	enum isAnyDigest =
		isDigest!TDigest ||
		is(TDigest : Digest);
}

version(DAuth_Unittest)
unittest
{
	struct Foo {}
	static assert(isAnyDigest!SHA1);
	static assert(isAnyDigest!SHA1Digest);
	static assert(!isAnyDigest!Foo);
	static assert(!isAnyDigest!Object);
}

/// Like std.digest.digest.DigestType, but also accepts OO-style digests
/// (ie. classes deriving from interface std.digest.digest.Digest)
template AnyDigestType(TDigest)
{
	static assert(isAnyDigest!TDigest,
		TDigest.stringof ~ " is not a template-style or OO-style digest (fails isAnyDigest!T)");
	
	static if(isDigest!TDigest)
		alias AnyDigestType = DigestType!TDigest;
	else
		alias AnyDigestType = ubyte[];
}

version(DAuth_Unittest)
unittest
{
	struct Foo {}
	static assert( is(AnyDigestType!SHA1 == ubyte[20]) );
	static assert( is(AnyDigestType!SHA1Digest == ubyte[]) );
	static assert( !is(AnyDigestType!Foo) );
	static assert( !is(AnyDigestType!Object) );
}

/// Tests if the type is an instance of struct Hash(some digest)
template isHash(T)
{
	enum isHash = is( Hash!(TemplateArgsOf!(T)[0]) == T );
}

version(DAuth_Unittest)
unittest
{
	struct Foo {}
	struct Bar(T) { T digest; }

	static assert( isHash!(Hash!SHA1) );
	static assert( isHash!(Hash!SHA1Digest) );

	static assert( !isHash!Foo              );
	static assert( !isHash!(Bar!int)        );
	static assert( !isHash!(Bar!Object)     );
	static assert( !isHash!(Bar!SHA1)       );
	static assert( !isHash!(Bar!SHA1Digest) );
}

/// Retreive the digest type of a struct Hash(some digest)
template DigestOf(T) if(isHash!T)
{
	alias DigestOf = TemplateArgsOf!(T)[0];
}

version(DAuth_Unittest)
unittest
{
	static assert(is( DigestOf!(Hash!SHA1  ) == SHA1  ));
	static assert(is( DigestOf!(Hash!Digest) == Digest));
}

string getDigestCode(TDigest)(string function(Digest) digestCodeOfObj, TDigest digest)
	if(isAnyDigest!TDigest)
{
	static if(is(TDigest : Digest))
		return digestCodeOfObj(digest);
	else
	{
		auto digestObj = new WrapperDigest!TDigest();
		return digestCodeOfObj(digestObj);
	}
}

/// A reference-counted type for passwords. The memory containing the password
/// is automatically zeroed-out when there are no more references or when
/// a new password is assigned.
///
/// If you keep any direct references to Password.data, be aware it may get cleared.
alias Password = RefCounted!PasswordData;

/// Payload of Password
private struct PasswordData
{
	private ubyte[] _data;
	
	@property ubyte[] data()
	{
		return _data;
	}
	
	@property size_t length() const
	{
		return _data.length;
	}
	
	void opAssign(PasswordData rhs)
	{
		opAssign(rhs._data);
	}
	
	void opAssign(ubyte[] rhs)
	{
		clear();
		this._data = rhs;
	}
	
	~this()
	{
		clear();
	}

	private void clear()
	{
		_data[] = 0;
	}
}

Password toPassword(ubyte[] password)
{
	return Password(password);
}

Password toPassword(char[] password)
{
	return Password(cast(ubyte[])password);
}

/// This function exists as a convenience in case you need it, HOWEVER it's
/// recommended to design your code so you DON'T need to use this:
/// Using this to create a Password cannot protect the in-memory data of your
/// original string because a string's data is immutable (this function must
/// .dup the memory).
///
/// While immutability usually improves safety, you should avoid ever storing
/// unhashed passwords in immutables because they cannot be reliably
/// zero-ed out.
Password dupPassword(string password)
{
	return toPassword(password.dup);
}

/// Contains all the relevent information for a salted hash.
/// Note the digest type can be obtained via DigestOf!(SomeHashType).
struct Hash(TDigest) if(isAnyDigest!TDigest)
{
	Salt salt;       /// The salt that was used.
	
	/// The hash of the salted password. To obtain a printable DB-friendly
	/// string, pass this to std.digest.digest.toHexString.
	AnyDigestType!TDigest hash;
	
	/// The digest that was used for hashing.
	TDigest digest;
	
	/// Encodes the digest, salt and hash into a convenient forward-compatible
	/// string format, ready for insertion into a database.
	///
	/// To support additional digests besides the built-in (Phobos's CRC32, MD5,
	/// RIPEMD160 and SHA1), supply a custom function for digestCodeOfObj.
	/// Your custom digestCodeOfObj only needs to handle OO-style digests.
	/// As long as the OO-style digests were created using Phobos's
	/// WrapperDigest template, the template-style version will be handled
	/// automatically. You can defer to DAuth's defaultDigestCodeOfObj to
	/// handle the built-in digests.
	///
	/// Example:
	/// -------------------
	/// import std.digest.digest;
	/// import dauth;
	/// 
	/// struct BBQ42 {...}
	/// static assert(isDigest!BBQ42);
	/// alias BBQ42Digest = WrapperDigest!BBQ42;
	/// 
	/// string customDigestCodeOfObj(Digest digest)
	/// {
	///     if     (cast(BBQ42Digest)digest) return "BBQ42";
	///     else if(cast(FAQ17Digest)digest) return "FAQ17";
	///     else
	///         return defaultDigestCodeOfObj(digest);
	/// }
	/// 
	/// void doStuff(Hash!BBQ42 hash)
	/// {
	///     writeln( hash.toString(&customDigestCodeOfObj) );
	/// }
	/// -------------------
	string toString(string function(Digest) digestCodeOfObj = &defaultDigestCodeOfObj)
	{
		Appender!string sink;
		toString(sink, digestCodeOfObj);
		return sink.data;
	}

	///ditto
	void toString(Sink)(ref Sink sink, string function(Digest) digestCodeOfObj = &defaultDigestCodeOfObj)
		if(isOutputRange!(Sink, const(char)))
	{
		sink.put('[');
		sink.put(getDigestCode(digestCodeOfObj, digest));
		sink.put(']');
		Base64.encode(salt, sink);
		sink.put('$');
		Base64.encode(hash, sink);
	}
}

/++
Generates a salted password using any Phobos-compatible digest, default being SHA1.

(Note: SHA1 is a poor choice for password hashes since it's fast
and therefore susceptible to parallelized (ex: GPU) brute-force attack.
A cryptographically-slow algorithm designed for password hashing should
be used instead, but SHA1 is the best Phobos has at the moment.)

Supports both template-style and OO-style digests. See the documentation of
std.digest.digest for details.

Salt is optional. It will be generated at random if not provided.

Normally, the salt and password are combined as (psuedocode) 'salt~password'.
There is no cryptographic benefit to combining the salt and password any
other way. However, if you need to support an alternate method for
compatibility purposes, you can do so by providing a custom salter function.
See the implementation of DAuth's defaultSalter to see how to do this.
+/
Hash!TDigest makeHash(TDigest = DefaultDigest)
	(Password password, Salt salt = randomSalt(), Salter!TDigest salter = &defaultSalter!TDigest)
	if(isDigest!TDigest)
{
	validateStrength!TDigest();
	TDigest digest;
	return makeHashImpl!TDigest(digest, password, salt, salter);
}

///ditto
Hash!TDigest makeHash(TDigest = DefaultDigest)(Password password, Salter!TDigest salter)
	if(isDigest!TDigest)
{
	validateStrength!TDigest();
	TDigest digest;
	return makeHashImpl(digest, password, randomSalt(), salter);
}

///ditto
Hash!Digest makeHash()(Digest digest, Password password, Salt salt = randomSalt(),
	Salter!Digest salter = &defaultSalter!Digest)
{
	validateStrength(digest);
	return makeHashImpl!Digest(digest, password, salt, salter);
}

///ditto
Hash!Digest makeHash()(Digest digest, Password password, Salter!Digest salter)
{
	validateStrength(digest);
	return makeHashImpl!Digest(digest, password, randomSalt(), salter);
}

private Hash!TDigest makeHashImpl(TDigest)
	(ref TDigest digest, Password password, Salt salt, Salter!TDigest salter)
	if(isAnyDigest!TDigest)
{
	Hash!TDigest ret;
	ret.digest = digest;
	ret.salt   = salt;
	
	static if(isDigest!TDigest) // template-based digest
		ret.digest.start();
	else
		ret.digest.reset(); // OO-based digest
	
	salter(ret.digest, password, salt);
	ret.hash = ret.digest.finish();
	
	return ret;
}

/// Parses a string that was encoded by Hash.toString.
///
/// Only OO-style digests are used since the digest is specified in the string
/// and therefore only known at runtime.
///
/// Throws ConvException if the string is malformed.
///
/// To support additional digests besides the built-in (Phobos's CRC32, MD5,
/// RIPEMD160 and SHA1), supply a custom function for digestFromCode.
/// You can defer to DAuth's defaultDigestFromCode to handle the
/// built-in digests.
///
/// Example:
/// -------------------
/// import std.digest.digest;
/// import dauth;
/// 
/// struct BBQ42 {...}
/// static assert(isDigest!BBQ42);
/// alias BBQ42Digest = WrapperDigest!BBQ42;
/// 
/// Digest customDigestFromCode(string digestCode)
/// {
///     switch(digestCode)
///     {
///     case "BBQ42": return new BBQ42Digest();
///     case "FAQ17": return new FAQ17Digest();
///     default:
///         return defaultDigestFromCode(digestCode);
///     }
/// }
/// 
/// void doStuff(string hashString)
/// {
///     auto hash = parseHash(hashString, &customDigestFromCode);
/// }
/// -------------------
Hash!Digest parseHash(string str,
	Digest function(string) digestFromCode = &defaultDigestFromCode)
{
	// No need to mess with UTF
	auto bytes = cast(immutable(ubyte)[]) str;
	
	// Parse '['
	enforceEx!ConvException(!bytes.empty);
	enforceEx!ConvException(bytes.front == cast(ubyte)'[');
	bytes.popFront();

	// Parse digest code
	auto splitRBracket = bytes.findSplit([']']);
	enforceEx!ConvException( !splitRBracket[0].empty && !splitRBracket[1].empty && !splitRBracket[2].empty );
	auto digestCode = splitRBracket[0];
	bytes = splitRBracket[2];
	
	// Split salt and hash
	auto splitDollar = bytes.findSplit(['$']);
	enforceEx!ConvException( !splitDollar[0].empty && !splitDollar[1].empty && !splitDollar[2].empty );
	auto salt = splitDollar[0];
	auto hash = splitDollar[2];
	
	// Construct Hash
	Hash!Digest result;
	result.salt   = Base64.decode(salt);
	result.hash   = Base64.decode(hash);
	result.digest = digestFromCode(cast(string)digestCode);
	
	return result;
}

/// Validates a password against an existing salted hash.
bool isPasswordCorrect(TDigest = DefaultDigest)(Password password, Hash!TDigest sHash,
	Salter!TDigest salter = &defaultSalter!TDigest)
	if(isAnyDigest!TDigest)
{
	auto testHash = makeHash!TDigest(password, sHash.salt, salter);
	return lengthConstantEquals(testHash.hash, sHash.hash);
}

///ditto
bool isPasswordCorrect(TDigest = DefaultDigest)
	(Password password, DigestType!TDigest hash, Salt salt,
		Salter!TDigest salter = &defaultSalter!TDigest)
	if(isDigest!TDigest)
{
	auto testHash = makeHash!TDigest(password, salt, salter);
	return lengthConstantEquals(testHash.hash, hash);
}

///ditto
bool isPasswordCorrect()(Password password,
	ubyte[] hash, Salt salt, Digest digest = new DefaultDigestClass(),
	Salter!Digest salter = &defaultSalter!Digest)
{
	auto testHash = makeHash(digest, password, salt, salter);
	return lengthConstantEquals(testHash.hash, hash);
}

///ditto
bool isPasswordCorrect()(Password password,
	ubyte[] hash, Salt salt, Salter!Digest salter)
{
	auto testHash = makeHash(new DefaultDigestClass(), password, salt, salter);
	return lengthConstantEquals(testHash.hash, hash);
}

version(DAuth_Unittest)
unittest
{
	// For validity of sanity checks, these sha1 and base64 strings
	// were NOT generated using Phobos.
	auto plainText1      = dupPassword("hello world");
	enum sha1Hash1       = cast(ubyte[20]) x"2aae6c35c94fcfb415dbe95f408b9ce91ee846ed";
	enum sha1Hash1Base64 = "Kq5sNclPz7QV2+lfQIuc6R7oRu0=";

	auto plainText2      = dupPassword("some salt");
	enum sha1Hash2       = cast(ubyte[20]) x"78bc8b0e186b0aa698f12dc27736b492e4dacfc8";
	enum sha1Hash2Base64 = "eLyLDhhrCqaY8S3Cdza0kuTaz8g=";
	
	unitlog("Sanity checking unittest's data");
	assert(sha1Of(plainText1.data) == sha1Hash1);
	assert(sha1Of(plainText2.data) == sha1Hash2);
	assert(Base64.encode(sha1Hash1) == sha1Hash1Base64);
	assert(Base64.encode(sha1Hash2) == sha1Hash2Base64);

	unitlog("Testing Hash.toString");
	Hash!SHA1 result1;
	result1.hash = cast(AnyDigestType!SHA1) sha1Hash1;
	result1.salt = cast(Salt)               sha1Hash2;
	assert( result1.toString() == text("[SHA1]", sha1Hash2Base64, "$", sha1Hash1Base64) );
	
	unitlog("Testing makeHash([digest,] pass, salt [, salter])");
	static void altSalter(TDigest)(ref TDigest digest, Password password, Salt salt)
	{
		// Reverse order
		digest.put(password.data);
		digest.put(cast(immutable(ubyte)[])salt);
	}
	
	auto result2          = makeHash!SHA1(plainText1, cast(Salt)sha1Hash2[]);
	auto result2AltSalter = makeHash!SHA1(plainText1, cast(Salt)sha1Hash2[], &altSalter!SHA1);
	auto result3          = makeHash(new SHA1Digest(), plainText1, cast(Salt)sha1Hash2[]);
	auto result3AltSalter = makeHash(new SHA1Digest(), plainText1, cast(Salt)sha1Hash2[], &altSalter!Digest);

	assert(result2.salt       == result3.salt);
	assert(result2.hash       == result3.hash);
	assert(result2.toString() == result3.toString());
	assert(result2.toString() == makeHash!SHA1(plainText1, cast(Salt)sha1Hash2[]).toString());

	assert(result2.salt == result1.salt);

	assert(result2AltSalter.salt       == result3AltSalter.salt);
	assert(result2AltSalter.hash       == result3AltSalter.hash);
	assert(result2AltSalter.toString() == result3AltSalter.toString());
	assert(result2AltSalter.toString() == makeHash!SHA1(plainText1, cast(Salt)sha1Hash2[], &altSalter!SHA1).toString());
	
	assert(result2.salt       == result2AltSalter.salt);
	assert(result2.hash       != result2AltSalter.hash);
	assert(result2.toString() != result2AltSalter.toString());

	unitlog("Testing makeHash(pass)");
	auto resultRand1 = makeHash!SHA1(randomPassword());
	auto resultRand2 = makeHash!SHA1(randomPassword());

	assert(resultRand1.salt != result1.salt);

	assert(resultRand1.salt != resultRand2.salt);
	assert(resultRand1.hash != resultRand2.hash);

	unitlog("Testing parseHash(void)");
	auto result2Parsed = parseHash( result2.toString() );
	assert(result2.salt       == result2Parsed.salt);
	assert(result2.hash       == result2Parsed.hash);
	assert(result2.toString() == result2Parsed.toString());
	
	unitlog("Testing isPasswordCorrect");
	assert(isPasswordCorrect     (plainText1, result2));
	assert(isPasswordCorrect!SHA1(plainText1, result2.hash, result2.salt));
	assert(isPasswordCorrect     (plainText1, result2.hash, result2.salt, new SHA1Digest()));

	assert(isPasswordCorrect!SHA1(plainText1, result2AltSalter, &altSalter!SHA1));
	assert(isPasswordCorrect!SHA1(plainText1, result2AltSalter.hash, result2AltSalter.salt, &altSalter!SHA1));
	assert(isPasswordCorrect     (plainText1, result2AltSalter.hash, result2AltSalter.salt, new SHA1Digest(), &altSalter!Digest));

	assert(!isPasswordCorrect     (dupPassword("bad pass"), result2));
	assert(!isPasswordCorrect!SHA1(dupPassword("bad pass"), result2.hash, result2.salt));
	assert(!isPasswordCorrect     (dupPassword("bad pass"), result2.hash, result2.salt, new SHA1Digest()));

	assert(!isPasswordCorrect!SHA1(dupPassword("bad pass"), result2AltSalter, &altSalter!SHA1));
	assert(!isPasswordCorrect!SHA1(dupPassword("bad pass"), result2AltSalter.hash, result2AltSalter.salt, &altSalter!SHA1));
	assert(!isPasswordCorrect     (dupPassword("bad pass"), result2AltSalter.hash, result2AltSalter.salt, new SHA1Digest(), &altSalter!Digest));

	auto wrongSalt = result2;
	wrongSalt.salt = wrongSalt.salt[4..$-1];
	
	assert(!isPasswordCorrect     (plainText1, wrongSalt));
	assert(!isPasswordCorrect!SHA1(plainText1, wrongSalt.hash, wrongSalt.salt));
	assert(!isPasswordCorrect     (plainText1, wrongSalt.hash, wrongSalt.salt, new SHA1Digest()));

	Hash!MD5 wrongDigest;
	wrongDigest.salt = result2.salt;
	wrongDigest.hash = cast(ubyte[16])result2.hash[0..16];
	
	assert(!isPasswordCorrect    (plainText1, wrongDigest));
	assert(!isPasswordCorrect!MD5(plainText1, wrongDigest.hash, wrongDigest.salt));
	assert(!isPasswordCorrect    (plainText1, wrongDigest.hash, wrongDigest.salt, new MD5Digest()));
}

/++
Generates a random password.

This is limited to generating ASCII passwords. This is because including
non-ASCII characters in generated passwords is more complex, more error-prone,
more likely to trigger latent unicode bugs in other systems, and not
particularly useful anyway.

Throws an Exception if passwordChars.length isn't at least 2.

USE THIS RESPONSIBLY! NEVER EMAIL THE PASSWORD! Emailing a generated password
to a user is a highly insecure practice and should NEVER be done. However,
there are other times when generating a password may be reasonable, so this is
provided as a convenience.
+/
Password randomPassword(Rand = DefaultCryptoRand) (
	size_t length = defaultPasswordLength,
	const(ubyte)[] passwordChars = defaultPasswordChars
)
if(isUniformRNG!Rand)
out(result)
{
	assert(result.length == length);
}
body
{
	Rand rand;
	rand.initRand();
	return randomPassword(rand, length, passwordChars);
}

///ditto
Password randomPassword(Rand = DefaultCryptoRand) (
	ref Rand rand,
	size_t length = defaultPasswordLength,
	const(ubyte)[] passwordChars = defaultPasswordChars
)
if(isUniformRNG!Rand)
out(result)
{
	assert(result.length == length);
}
body
{
	Appender!(ubyte[]) sink;
	randomPassword(rand, sink, length, passwordChars);
	return toPassword(sink.data);
}

///ditto
void randomPassword(Rand = DefaultCryptoRand, Sink)(
	ref Sink sink,
	size_t length = defaultPasswordLength,
	const(ubyte)[] passwordChars = defaultPasswordChars
)
if( isUniformRNG!Rand && isOutputRange!(Sink, ubyte) )
{
	Rand rand;
	rand.initRand();
	randomPassword(rand, sink, length, passwordChars);
}

///ditto
void randomPassword(Rand = DefaultCryptoRand, Sink) (
	ref Rand rand, ref Sink sink,
	size_t length = defaultPasswordLength,
	const(ubyte)[] passwordChars = defaultPasswordChars
)
if( isUniformRNG!Rand && isOutputRange!(Sink, ubyte) )
{
	enforce(passwordChars.length >= 2);
	
	rand.popFront(); // Ensure fresh data
	foreach(i; 0..length)
	{
		auto charIndex = rand.front % passwordChars.length;
		sink.put(passwordChars[charIndex]);
		rand.popFront();
	}
}

version(DAuth_Unittest)
unittest
{
	unitlog("Testing randomPassword");

	void validateChars(Password pass, immutable(ubyte)[] validChars, size_t length)
	{
		foreach(i; 0..pass.data.length)
		{
			assert(
				validChars.canFind( cast(ubyte)pass.data[i] ),
				text(
					"Invalid char `", pass.data[i],
					"` (ascii ", cast(ubyte)pass.data[i], ") at index ", i,
					" in password length ", length,
					". Valid char set: ", validChars
				)
			);
		}
	}
	
	// Ensure non-purity
	assert(randomPassword() != randomPassword());
	assert(randomPassword!MinstdRand() != randomPassword!MinstdRand());
	auto randA = MinstdRand(unpredictableSeed);
	auto randB = MinstdRand(unpredictableSeed);
	assert(randomPassword(randA) != randomPassword(randB));
	
	// Ensure length, valid chars and non-purity:
	//     Default RNG, length and charset. Non-sink.
	Password prevPass;
	foreach(i; 0..10)
	{
		auto pass = randomPassword();
		assert(pass.length == defaultPasswordLength);
		validateChars(pass, defaultPasswordChars, defaultPasswordLength);
		
		assert(pass != prevPass);
		prevPass = pass;
	}

	// Test argument-checking
	assertThrown(randomPassword(5, []));
	assertThrown(randomPassword(5, ['X']));

	// Ensure length, valid chars and non-purity:
	//     Default and provided RNGs. With/without sink. Various lengths and charsets.
	auto charsets = [
		defaultPasswordChars,
		defaultPasswordChars ~ cast(immutable(ubyte)[])".,<>",
		cast(immutable(ubyte)[]) "abc123",
		cast(immutable(ubyte)[]) "XY"
	];
	foreach(validChars; charsets)
	foreach(length; [defaultPasswordLength, 5, 2])
	foreach(i; 0..2)
	{
		Password pass;
		MinstdRand rand;
		Appender!(ubyte[]) sink;
		
		// -- Non-sink -------------

		// Default RNG
		pass = randomPassword(length, validChars);
		assert(pass.length == length);
		validateChars(pass, validChars, length);
		if(validChars.length > 25)
			assert(pass != randomPassword(length, validChars));
		
		// Provided RNG type
		pass = randomPassword!MinstdRand(length, validChars);
		assert(pass.length == length);
		validateChars(pass, validChars, length);
		if(validChars.length > 25)
			assert(pass != randomPassword!MinstdRand(length, validChars));
		
		// Provided RNG object
		rand = MinstdRand(unpredictableSeed);
		pass = randomPassword(rand, length, validChars);
		assert(pass.length == length);
		validateChars(pass, validChars, length);
		if(validChars.length > 25)
			assert(pass != randomPassword(rand, length, validChars));
		
		// -- With sink -------------

		// Default RNG
		sink = appender!(ubyte[])();
		randomPassword(sink, length, validChars);
		pass = toPassword(sink.data);
		assert(pass.length == length);
		validateChars(pass, validChars, length);
		if(validChars.length > 25)
		{
			sink = appender!(ubyte[])();
			randomPassword(sink, length, validChars);
			assert(pass.data != sink.data);
		}
		
		// Provided RNG type
		sink = appender!(ubyte[])();
		randomPassword!MinstdRand(sink, length, validChars);
		pass = toPassword(sink.data);
		assert(pass.length == length);
		validateChars(pass, validChars, length);
		if(validChars.length > 25)
		{
			sink = appender!(ubyte[])();
			randomPassword!MinstdRand(sink, length, validChars);
			assert(pass.data != sink.data);
		}
		
		// Provided RNG object
		sink = appender!(ubyte[])();
		rand = MinstdRand(unpredictableSeed);
		randomPassword(rand, sink, length, validChars);
		pass = toPassword(sink.data);
		assert(pass.length == length);
		validateChars(pass, validChars, length);
		if(validChars.length > 25)
		{
			sink = appender!(ubyte[])();
			randomPassword(rand, sink, length, validChars);
			assert(pass.data != sink.data);
		}
	}
}

/++
Generates a random salt. Necessary for salting passwords.

NEVER REUSE A SALT! This must be called separately EVERY time any user sets
or resets a password. Reusing salts defeats the security of salting passwords.

The length must be a multiple of 4, or this will throw an Exception

WARNING! Mt19937 (the default here) is not a "Cryptographically secure
pseudorandom number generator"
+/
Salt randomSalt(Rand = DefaultCryptoRand)(size_t length = defaultSaltLength)
	if(isUniformRNG!Rand)
{
	return randomBytes!Rand(length);
}

///ditto
Salt randomSalt(Rand = DefaultCryptoRand)(ref Rand rand, size_t length = defaultSaltLength)
	if(isUniformRNG!Rand)
{
	return randomBytes(length, rand);
}

version(DAuth_Unittest)
unittest
{
	unitlog("Testing randomSalt");

	// Ensure non-purity
	assert(randomSalt() != randomSalt());
	assert(randomSalt!MinstdRand() != randomSalt!MinstdRand());
	auto randA = MinstdRand(unpredictableSeed);
	auto randB = MinstdRand(unpredictableSeed);
	assert(randomSalt(randA) != randomSalt(randB));
	
	// Ensure zero-length case doesn't blow up
	assert(randomSalt(0).empty);
	assert(randomSalt(randA, 0).empty);

	// Test argument-checking (length not multiple of 4)
	assertThrown(randomSalt(5));
	assertThrown(randomSalt(6));
	assertThrown(randomSalt(7));

	// Ensure length and non-purity:
	//     Default and provided RNGs. Various lengths.
	foreach(length; [defaultSaltLength, 20, 8])
	foreach(i; 0..2)
	{
		Salt salt;
		
		// Default RNG
		salt = randomSalt(length);
		assert(salt.length == length);
		assert(salt != randomSalt(length));
		
		// Provided RNG type
		salt = randomSalt!MinstdRand(length);
		assert(salt.length == length);
		assert(salt != randomSalt!MinstdRand(length));
		
		// Provided RNG object
		auto rand = MinstdRand(unpredictableSeed);
		salt = randomSalt(rand, length);
		assert(salt.length == length);
		assert(salt != randomSalt(rand, length));
	}
}

/++
Generates a random token. Useful for temporary one-use URLs, such as in
email confirmations.

The strength is the number of bytes of randomness in the token.
Note this is NOT the length of the token string returned, since this token is
base64-encoded (using an entirely URI-safe version that doesn't need escaping)
from the raw random bytes.

The strength must be a multiple of 4, or this will throw an Exception

WARNING! Mt19937 (the default here) is not a "Cryptographically secure
pseudorandom number generator"
+/
string randomToken(Rand = DefaultCryptoRand)(size_t strength = defaultTokenStrength)
	if(isUniformRNG!Rand)
{
	return TokenBase64.encode( randomBytes!Rand(strength) );
}

///ditto
string randomToken(Rand = DefaultCryptoRand)(ref Rand rand, size_t strength = defaultTokenStrength)
	if(isUniformRNG!Rand)
{
	return TokenBase64.encode( randomBytes(strength, rand) );
}

version(DAuth_Unittest)
unittest
{
	unitlog("Testing randomToken");
	
	// Ensure non-purity
	assert(randomToken() != randomToken());
	assert(randomToken!MinstdRand() != randomToken!MinstdRand());
	auto randA = MinstdRand(unpredictableSeed);
	auto randB = MinstdRand(unpredictableSeed);
	assert(randomToken(randA) != randomToken(randB));
	
	// Ensure zero-strength case doesn't blow up
	assert(randomToken(0).empty);
	assert(randomToken(randA, 0).empty);

	// Test argument-checking (strength not multiple of 4)
	assertThrown(randomToken(5));
	assertThrown(randomToken(6));
	assertThrown(randomToken(7));

	// Ensure length, valid chars and non-purity:
	//     Default and provided RNGs. Various lengths.
	foreach(strength; [defaultTokenStrength, 20, 8])
	foreach(i; 0..2)
	{
		string token;
		MinstdRand rand;
		
		import std.math : ceil;
		
		// Default RNG
		token = randomToken(strength);
		// 6 bits per Base64-encoded byte vs. 8 bits per input (strength) byte
		// (with input length rounded up to the next multiple of 3)
		assert(token.length * 6 == (ceil(strength/3.0L)*3) * 8);
		assert(TokenBase64.decode(token));
		assert(token != randomToken(strength));
		
		// Provided RNG type
		token = randomToken!MinstdRand(strength);
		assert(token.length * 6 == (ceil(strength/3.0L)*3) * 8);
		assert(TokenBase64.decode(token));
		assert(token != randomToken!MinstdRand(strength));
		
		// Provided RNG object
		rand = MinstdRand(unpredictableSeed);
		token = randomToken(rand, strength);
		assert(token.length * 6 == (ceil(strength/3.0L)*3) * 8);
		assert(TokenBase64.decode(token));
		assert(token != randomToken(rand, strength));
	}
}

/// WARNING! Mt19937 (the default here) is not a "Cryptographically secure
/// pseudorandom number generator"
///
/// numBytes must be a multiple of 4, or this will throw an Exception
ubyte[] randomBytes(Rand = DefaultCryptoRand)(size_t numBytes)
	if(isUniformRNG!Rand)
{
	Rand rand;
	rand.initRand();
	return randomBytes(numBytes, rand);
}

///ditto
ubyte[] randomBytes(Rand = DefaultCryptoRand)(size_t numBytes, ref Rand rand)
	if(isUniformRNG!Rand)
out(result)
{
	assert(result.length == numBytes);
}
body
{
	enforce(numBytes % 4 == 0, "numBytes must be multiple of 4, not "~to!string(numBytes));
	rand.popFront(); // Ensure fresh data
	return cast(ubyte[])( rand.take(numBytes/4).array() );
}

private void initRand(Rand)(ref Rand rand)
	if(isUniformRNG!Rand)
{
	if(isSeedable!Rand)
		rand.seed(unpredictableSeed);
}

/++
Compare two arrays in "length-constant" time. This thwarts timing-based
attacks by guaranteeing all comparisons (of a given length) take the same
amount of time.

See the section "Why does the hashing code on this page compare the hashes in
"length-constant" time?" at:
    https://crackstation.net/hashing-security.htm
+/
bool lengthConstantEquals(ubyte[] a, ubyte[] b)
{
	auto diff = a.length ^ b.length;
	for(int i = 0; i < a.length && i < b.length; i++)
		diff |= a[i] ^ b[i];

	return diff == 0;
}

// Borrowed from Phobos master (Should arrive in DMD v2.066).
private template TemplateArgsOf(alias T : Base!Args, alias Base, Args...)
{
    alias TemplateArgsOf = Args;
}
private template TemplateArgsOf(T : Base!Args, alias Base, Args...)
{
    alias TemplateArgsOf = Args;
}
static assert(is( TemplateArgsOf!( Hash!SHA1   )[0] == SHA1   ));
static assert(is( TemplateArgsOf!( Hash!Digest )[0] == Digest ));
