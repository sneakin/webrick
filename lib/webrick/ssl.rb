# frozen_string_literal: false
#
# ssl.rb -- SSL/TLS enhancement for GenericServer
#
# Copyright (c) 2003 GOTOU Yuuzou All rights reserved.
#
# $Id$

require 'webrick'
require 'openssl'

module WEBrick
  module Config
    svrsoft = General[:ServerSoftware]
    osslv = ::OpenSSL::OPENSSL_VERSION.split[1]

    ##
    # Default SSL server configuration.
    #
    # WEBrick can automatically create a self-signed certificate if
    # <code>:SSLCertName</code> is set.  For more information on the various
    # SSL options see OpenSSL::SSL::SSLContext.
    #
    # :ServerSoftware       ::
    #   The server software name used in the Server: header.
    # :SSLEnable            :: false,
    #   Enable SSL for this server.  Defaults to false.
    # :SSLCertificate       ::
    #   The SSL certificate for the server.
    # :SSLPrivateKey        ::
    #   The SSL private key for the server certificate.
    # :SSLClientCA          :: nil,
    #   Array of certificates that will be sent to the client.
    # :SSLExtraChainCert    :: nil,
    #   Array of certificates that will be added to the certificate chain
    # :SSLCACertificateFile :: nil,
    #   Path to a CA certificate file
    # :SSLCACertificatePath :: nil,
    #   Path to a directory containing CA certificates
    # :SSLCertificateStore  :: nil,
    #   OpenSSL::X509::Store used for certificate validation of the client
    # :SSLTmpDhCallback     :: nil,
    #   Callback invoked when DH parameters are required.
    # :SSLVerifyClient      ::
    #   Sets whether the client is verified.  This defaults to VERIFY_NONE
    #   which is typical for an HTTPS server.
    # :SSLVerifyDepth       ::
    #   Number of CA certificates to walk when verifying a certificate chain
    # :SSLVerifyCallback    ::
    #   Custom certificate verification callback
    # :SSLServerNameCallback::
    #   Custom servername indication callback
    # :SSLTimeout           ::
    #   Maximum session lifetime
    # :SSLOptions           ::
    #   Various SSL options
    # :SSLCiphers           ::
    #   Ciphers to be used
    # :SSLStartImmediately  ::
    #   Immediately start SSL upon connection?  Defaults to true
    # :SSLCertName          ::
    #   SSL certificate name.  Must be set to enable automatic certificate
    #   creation.
    # :SSLCertComment       ::
    #   Comment used during automatic certificate creation.
    # :SSLCertAltName       ::
    #   subjectAltNames used for the certificate: DNS:example.com,IP:::1,IP:127.0.0.1

    SSL = {
      :ServerSoftware       => "#{svrsoft} OpenSSL/#{osslv}",
      :SSLEnable            => false,
      :SSLCertificate       => nil,
      :SSLPrivateKey        => nil,
      :SSLClientCA          => nil,
      :SSLExtraChainCert    => nil,
      :SSLCACertificateFile => nil,
      :SSLCACertificatePath => nil,
      :SSLCertificateStore  => nil,
      :SSLTmpDhCallback     => nil,
      :SSLVerifyClient      => ::OpenSSL::SSL::VERIFY_NONE,
      :SSLVerifyDepth       => nil,
      :SSLVerifyCallback    => nil,   # custom verification
      :SSLTimeout           => nil,
      :SSLOptions           => nil,
      :SSLCiphers           => nil,
      :SSLStartImmediately  => true,
      # Must specify if you use auto generated certificate.
      :SSLCertName          => nil,
      :SSLCertComment       => "Generated by Ruby/OpenSSL",
      :SSLCertAltName       => nil
    }
    General.update(SSL)
  end

  module Utils
    ##
    # Creates a self-signed certificate with the given number of +bits+,
    # the issuer +cn+ and a +comment+ to be stored in the certificate.

    def create_self_signed_cert(bits, cn, comment, opts = {})
      rsa = OpenSSL::PKey::RSA.new(bits){|p, n|
        case p
        when 0; $stderr.putc "."  # BN_generate_prime
        when 1; $stderr.putc "+"  # BN_generate_prime
        when 2; $stderr.putc "*"  # searching good prime,
                                  # n = #of try,
                                  # but also data from BN_generate_prime
        when 3; $stderr.putc "\n" # found good prime, n==0 - p, n==1 - q,
                                  # but also data from BN_generate_prime
        else;   $stderr.putc "*"  # BN_generate_prime
        end
      }
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = rand(65535)
      name = (cn.kind_of? String) ? OpenSSL::X509::Name.parse(cn)
                                  : OpenSSL::X509::Name.new(cn)
      cert.subject = name
      cert.issuer = name
      cert.not_before = Time.now - 48*60*60
      cert.not_after = Time.now + (365*24*60*60)
      cert.public_key = rsa.public_key

      ef = OpenSSL::X509::ExtensionFactory.new(nil,cert)
      ef.issuer_certificate = cert
      cert.extensions = [
        ef.create_extension("basicConstraints","CA:FALSE"),
        ef.create_extension("keyUsage", "keyEncipherment, dataEncipherment, digitalSignature, cRLSign, keyCertSign"),
        ef.create_extension("subjectKeyIdentifier", "hash"),
        ef.create_extension("extendedKeyUsage", "serverAuth"),
        ef.create_extension("nsComment", comment)
      ]
      cert.add_extension(ef.create_extension("subjectAltName", opts.fetch(:san))) if opts[:san]
      aki = ef.create_extension("authorityKeyIdentifier",
                                "keyid:always,issuer:always")
      cert.add_extension(aki)
      cert.sign(rsa, OpenSSL::Digest::SHA256.new)

      return [ cert, rsa ]
    end
    module_function :create_self_signed_cert
  end

  ##
  #--
  # Updates WEBrick::GenericServer with SSL functionality

  class GenericServer

    ##
    # SSL context for the server when run in SSL mode

    def ssl_context # :nodoc:
      @ssl_context ||= begin
        if @config[:SSLEnable]
          ssl_context = setup_ssl_context(@config)
          @logger.info("\n" + @config[:SSLCertificate].to_text)
          ssl_context
        end
      end
    end

    undef listen

    ##
    # Updates +listen+ to enable SSL when the SSL configuration is active.

    def listen(address, port) # :nodoc:
      listeners = Utils::create_listeners(address, port)
      if @config[:SSLEnable]
        listeners.collect!{|svr|
          ssvr = ::OpenSSL::SSL::SSLServer.new(svr, ssl_context)
          ssvr.start_immediately = @config[:SSLStartImmediately]
          ssvr
        }
      end
      @listeners += listeners
      setup_shutdown_pipe
    end

    ##
    # Sets up an SSL context for +config+

    def setup_ssl_context(config) # :nodoc:
      unless config[:SSLCertificate]
        cn = config[:SSLCertName]
        comment = config[:SSLCertComment]
        san = config[:SSLCertAltName]
        cert, key = Utils::create_self_signed_cert(2048, cn, comment, san: san)
        config[:SSLCertificate] = cert
        config[:SSLPrivateKey] = key
      end
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.key = config[:SSLPrivateKey]
      ctx.cert = config[:SSLCertificate]
      ctx.client_ca = config[:SSLClientCA]
      ctx.extra_chain_cert = config[:SSLExtraChainCert]
      ctx.ca_file = config[:SSLCACertificateFile]
      ctx.ca_path = config[:SSLCACertificatePath]
      ctx.cert_store = config[:SSLCertificateStore]
      ctx.tmp_dh_callback = config[:SSLTmpDhCallback]
      ctx.verify_mode = config[:SSLVerifyClient]
      ctx.verify_depth = config[:SSLVerifyDepth]
      ctx.verify_callback = config[:SSLVerifyCallback]
      ctx.servername_cb = config[:SSLServerNameCallback] || proc { |args| ssl_servername_callback(*args) }
      ctx.timeout = config[:SSLTimeout]
      ctx.options = config[:SSLOptions]
      ctx.ciphers = config[:SSLCiphers]
      ctx
    end

    ##
    # ServerNameIndication callback

    def ssl_servername_callback(sslsocket, hostname = nil)
      # default
    end

  end
end
