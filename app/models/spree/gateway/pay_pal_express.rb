require 'paypal-sdk-merchant'
module Spree
  class Gateway::PayPalExpress < Gateway

    preference :login, :string
    preference :password, :string
    preference :signature, :string
    preference :seller_account_email, :string
    preference :server, :string, default: 'sandbox'
    preference :solution, :string, default: 'Mark'
    preference :landing_page, :string, default: 'Billing'
    preference :logourl, :string, default: ''

    cattr_accessor :button_source

    def supports?(source)
      true
    end

    def provider_class
      ::PayPal::SDK::Merchant::API
    end

    def provider
      ::PayPal::SDK.configure(
        :mode      => preferred_server.present? ? preferred_server : "sandbox",
        :subject   => preferred_seller_account_email.present? ? preferred_seller_account_email : nil,
        :username  => preferred_login,
        :password  => preferred_password,
        :signature => preferred_signature)
      provider_class.new
    end

    def auto_capture?
      true
    end

    def method_type
      'paypal'
    end

    def purchase(amount, express_checkout, gateway_options={})
      pp_details_request = provider.build_get_express_checkout_details({
        :Token => express_checkout.token
      })
      pp_details_response = provider.get_express_checkout_details(pp_details_request)

      # HACK: fix bug where subject email without associated paypal account fails payment (paypal returns 10002 unauthorized error)
      # the GetExpressCheckoutDetails call returns "PaypalAccountID" in
      # pp_details_response.get_express_checkout_details_response_details.payment_details.seller_details.pay_pal_account_id
      # Since we only use the "subject" field, rather than specifying the specific account id, we want that
      # value to be empty. If it's not empty (such as when GetExpressCheckoutDetails returns is), PayPal rejects transactions.
      # PayPal is supposed to be looking into why this value is returned and hopefully fix (as of 12/4/2014).
      # IF they get that fixed, we should be able to safely remove this line.
      # We usually only have 1 payment, but payment_details is an array, so nil the pay_pal_account_id for all payments
      pp_details_response.get_express_checkout_details_response_details.payment_details.each do |payment|
        payment.seller_details.pay_pal_account_id = nil
        payment.button_source = 'GoDaddy_online'
      end

      pp_request = provider.build_do_express_checkout_payment({
        :DoExpressCheckoutPaymentRequestDetails => {
          :PaymentAction => "Sale",
          :Token => express_checkout.token,
          :PayerID => express_checkout.payer_id,
          :PaymentDetails => pp_details_response.get_express_checkout_details_response_details.PaymentDetails,
          # set ButtonSource for partner indicator: https://www.paypal-marketing.com/emarketing/partner/na/portal/integrate_bn_codes.html#ec
          # if not set, ButtonSource defaults to "PayPal_SDK" in the PayPal SDK library
          :ButtonSource => button_source
        }
      })

      pp_response = provider.do_express_checkout_payment(pp_request)
      if pp_response.success?
        # We need to store the transaction id for the future.
        # This is mainly so we can use it later on to refund the payment if the user wishes.
        transaction_id = pp_response.do_express_checkout_payment_response_details.payment_info.first.transaction_id
        express_checkout.update_column(:transaction_id, transaction_id)
        # This is rather hackish, required for payment/processing handle_response code.
        class << pp_response
          def authorization; nil; end
        end
      else
        class << pp_response
          def to_s
            errors.map(&:long_message).join(" ")
          end
        end
      end
      pp_response
    end

    def refund(payment, amount)
      refund_type = payment.amount == amount.to_f ? "Full" : "Partial"
      refund_transaction = provider.build_refund_transaction({
        :TransactionID => payment.source.transaction_id,
        :RefundType => refund_type,
        :Amount => {
          :currencyID => payment.currency,
          :value => amount },
        :RefundSource => "any" })
      refund_transaction_response = provider.refund_transaction(refund_transaction)
      if refund_transaction_response.success?
        payment.source.update_attributes({
          :refunded_at => Time.now,
          :refund_transaction_id => refund_transaction_response.RefundTransactionID,
          :state => "refunded",
          :refund_type => refund_type
        })

        payment.class.create!(
          :order => payment.order,
          :source => payment,
          :payment_method => payment.payment_method,
          :amount => amount.to_f.abs * -1,
          :response_code => refund_transaction_response.RefundTransactionID,
          :state => 'completed'
        )
      end
      refund_transaction_response
    end
  end
end

#   payment.state = 'completed'
#   current_order.state = 'complete'
