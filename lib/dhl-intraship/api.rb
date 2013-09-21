require 'savon'

module Dhl
  module Intraship
    class API

      DEFAULT_NAMESPACES = {
        "xmlns:is" => "http://de.ws.intraship",
        "xmlns:cis" => "http://dhl.de/webservice/cisbase"
      }

      INTRASHIP_WSDL = "http://www.intraship.de/ws/1_0/ISService/DE.wsdl"
      INTRASHIP_ENDPOINT = "http://www.intraship.de/ws/1_0/de/ISService"
      INTRASHIP_TEST_WSDL = "http://test-intraship.dhl.com/ws/1_0/ISService/DE.wsdl"
      INTRASHIP_TEST_ENDPOINT = "http://test-intraship.dhl.com/ws/1_0/de/ISService"

      def initialize(config, options = {})
        raise "User must be specified" if config[:user].nil?
        raise "Signature (password) must be specified" if config[:signature].nil?
        raise "EKP (first part of the DHL account number) must be specified" if config[:ekp].nil?

        if options[:test]
          wsdl_url = INTRASHIP_TEST_WSDL
          endpoint = INTRASHIP_TEST_ENDPOINT
        else
          wsdl_url = INTRASHIP_WSDL
          endpoint = INTRASHIP_ENDPOINT
        end

        @user = config[:user]
        @signature = config[:signature]
        @ekp = config[:ekp]
        @procedure_id = config[:procedure_id] || '01'
        @partner_id = config[:partner_id] || '01'

        @options = options
        @client = ::Savon::Client.new(
          wsdl: wsdl_url,
          endpoint: endpoint,
          namespaces: DEFAULT_NAMESPACES,
          soap_header: authentification_header,
          pretty_print_xml: true,
          log_level: :debug
        )
      end

      def createShipmentDD(shipments)
        begin
          shipments = [shipments] unless shipments.respond_to?('each')

          returnXML = @config && @config[:label_response_type] && @config[:label_response_type] == :xml;

          xml = Builder::XmlMarkup.new
          add_version_information(xml)
          xml.ShipmentOrder do |xml|
            xml.SequenceNumber('1')
            shipments.each do |shipment|
              shipment.append_to_xml(@ekp, @partner_id, xml)
              xml.LabelResponseType('XML') if returnXML
            end
          end

          result = @client.call(:create_shipment_dd, message: xml.target!)

          r = result.body[:create_shipment_response]
          if r[:status][:status_code] == '0'
            shipment_number = r[:creation_state][:shipment_number][:shipment_number]

            if returnXML
              xml_label = r[:creation_state][:xmllabel]
              {shipment_number: shipment_number, xml_label: xml_label}
            else
              label_url = r[:creation_state][:labelurl]
              {shipment_number: shipment_number, label_url: label_url}
            end

          else
            raise "Intraship call failed with code #{r[:status][:status_code]}: #{r[:status][:status_message]} (Status messages: #{r[:creation_state][:status_message].to_s})"
          end
        rescue Savon::Error => error
          raise error
        end
      end

      def deleteShipmentDD(shipment_number)
        begin
          result = do_simple_shipment_number_only_request(:delete_shipment_dd, shipment_number)
          r = result.body[:delete_shipment_response]

          # Return true if successful
          raise "Intraship call failed with code #{r[:status][:status_code]}: #{r[:status][:status_message]} (Status messages: #{r[:deletion_state][:status].to_s})" unless r[:status][:status_code] == '0'

          true
        rescue Savon::Error => error
          raise error
        end
      end

      def doManifestDD(shipment_number)
        begin
          result = do_simple_shipment_number_only_request(:do_manifest_dd, shipment_number)
          r = result.body[:do_manifest_response]

          raise "Intraship call failed with code #{r[:status][:status_code]}: #{r[:status][:status_message]} (Status messages: #{r[:manifest_state][:status].to_s})" unless r[:status][:status_code] == '0'

          true
        rescue Savon::Error => error
          raise error
        end
      end

      def bookPickup(booking_information, pickup_address, contact_orderer = nil)
        warn "DHL does not yet support the book pickup call"

        raise "Booking information must be of type BookingInformation! Is #{booking_information}" unless booking_information.kind_of? BookingInformation
        raise "Pickup_address must be of type Address! Is #{pickup_address.class}" unless pickup_address.kind_of? Address
        raise "Contact orderer must be of type Address! Is #{contact_orderer.class}" unless contact_orderer.nil? or contact_orderer.kind_of? Address

        if booking_information.account.nil? and [:DDI, :DDN].include?(booking_information.product_id)
          booking_information.account = @ekp
        end
        if booking_information.attendance.nil?
          booking_information.attendance = @partner_id
        end

        begin
          xml = Builder::XmlMarkup.new
          add_version_information(xml)
          booking_information.append_to_xml(xml)
          xml.PickupAddress do |xml|
            pickup_address.append_to_xml(xml)
          end
          xml.ContactOrderer do |xml|
            contact_orderer.append_to_xml(xml)
          end unless contact_orderer.nil?

          result = @client.call(:book_pickup, message: xml.target!)
          r = result.body[:book_pickup_response]

          raise "Intraship call failed with code #{r[:status][:status_code]}: #{r[:status][:status_message]}" unless r[:status][:status_code] == '0'

          r[:confirmation_number]
        rescue Savon::Error => error
          raise error
        end
      end

      protected

        def authentification_header
          {
            "cis:Authentification" => {
              "cis:user" => @user,
              "cis:signature" => @signature,
              # "cis:accountNumber" => "#{@ekp}|#{@procedure_id}|#{@partner_id}", # deprecated
              "cis:type" => 0
            }
          }
        end

        def add_version_information(xml)
          xml.cis(:Version) do |xml|
            xml.cis(:majorRelease, '1')
            xml.cis(:minorRelease, '0')
          end
        end

        def do_simple_shipment_number_only_request(operation, shipment_number)
          xml = Builder::XmlMarkup.new
          add_version_information(xml)
          xml.ShipmentNumber do |xml|
            xml.cis(:shipmentNumber, shipment_number)
          end

          @client.call(operation, message: xml.target!)
        end
    end
  end
end
