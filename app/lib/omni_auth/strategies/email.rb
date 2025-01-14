require 'base64'

module OmniAuth
  module Strategies
    class Email
      include OmniAuth::Strategy

      def request_phase
        redirect "/sessions/email"
      end

      def callback_phase
        token = request.params['token']
        if token.blank?
          fail!(:authenticity_error)
        end

        # begin
          decoded_token = Token.decode(token)
        # rescue
          # fail!(:authenticity_error, $!) <-- return from it
        # end

        @email = decoded_token['iss'].to_s.downcase
        if @email.blank?
          fail!(:authenticity_error)
        end

        super
      end

      uid do
        Digest::SHA256.new.hexdigest(@email)
      end

      info do
        { 'email' => @email }
      end
    end
  end
end
