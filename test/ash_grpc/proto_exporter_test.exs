defmodule AshGrpc.ProtoExporterTest do
  use ExUnit.Case, async: true

  alias AshGrpc.ProtoExporter
  alias Google.Protobuf.DescriptorProto
  alias Google.Protobuf.FieldDescriptorProto
  alias Google.Protobuf.FileDescriptorProto
  alias Google.Protobuf.MethodDescriptorProto
  alias Google.Protobuf.ServiceDescriptorProto

  describe "GIVEN the proto exporter WHEN a descriptor is rendered as proto source" do
    test "THEN syntax, package, messages and services are rendered" do
      file = %FileDescriptorProto{
        name: "ash_grpc/support/v1/tickets.proto",
        package: "ash_grpc.support.v1",
        syntax: "proto3",
        message_type: [
          %DescriptorProto{
            name: "SubmitTicketRequest",
            field: [
              %FieldDescriptorProto{
                name: "subject",
                number: 1,
                type: :TYPE_STRING,
                label: :LABEL_OPTIONAL
              },
              %FieldDescriptorProto{
                name: "body",
                number: 2,
                type: :TYPE_STRING,
                label: :LABEL_OPTIONAL
              }
            ]
          },
          %DescriptorProto{
            name: "SubmitTicketReply",
            field: [
              %FieldDescriptorProto{
                name: "ticket_id",
                number: 1,
                type: :TYPE_STRING,
                label: :LABEL_OPTIONAL
              },
              %FieldDescriptorProto{
                name: "tags",
                number: 2,
                type: :TYPE_STRING,
                label: :LABEL_REPEATED
              }
            ]
          }
        ],
        service: [
          %ServiceDescriptorProto{
            name: "Tickets",
            method: [
              %MethodDescriptorProto{
                name: "SubmitTicket",
                input_type: ".ash_grpc.support.v1.SubmitTicketRequest",
                output_type: ".ash_grpc.support.v1.SubmitTicketReply",
                client_streaming: false,
                server_streaming: false
              },
              %MethodDescriptorProto{
                name: "SubmitTicketBatch",
                input_type: ".ash_grpc.support.v1.SubmitTicketRequest",
                output_type: ".ash_grpc.support.v1.SubmitTicketReply",
                client_streaming: true,
                server_streaming: false
              }
            ]
          }
        ]
      }

      source = ProtoExporter.to_proto_source(file)

      assert source =~ ~s(syntax = "proto3";)
      assert source =~ "package ash_grpc.support.v1;"
      assert source =~ "message SubmitTicketRequest {"
      assert source =~ "  string subject = 1;"
      assert source =~ "  repeated string tags = 2;"
      assert source =~ "service Tickets {"

      assert source =~
               "rpc SubmitTicket (ash_grpc.support.v1.SubmitTicketRequest)" <>
                 " returns (ash_grpc.support.v1.SubmitTicketReply);"

      assert source =~
               "rpc SubmitTicketBatch (stream ash_grpc.support.v1.SubmitTicketRequest)" <>
                 " returns (ash_grpc.support.v1.SubmitTicketReply);"
    end

    test "THEN message-typed fields are rendered by their qualified name" do
      file = %FileDescriptorProto{
        syntax: "proto3",
        package: "demo",
        message_type: [
          %DescriptorProto{
            name: "Wrapper",
            field: [
              %FieldDescriptorProto{
                name: "created_at",
                number: 1,
                type: :TYPE_MESSAGE,
                type_name: ".google.protobuf.Timestamp",
                label: :LABEL_OPTIONAL
              }
            ]
          }
        ],
        service: []
      }

      source = ProtoExporter.to_proto_source(file)

      assert source =~ "  google.protobuf.Timestamp created_at = 1;"
    end

    test "THEN an empty message is rendered as an empty block with no fields" do
      file = %FileDescriptorProto{
        syntax: "proto3",
        package: "demo",
        message_type: [%DescriptorProto{name: "Empty", field: []}],
        service: []
      }

      assert ProtoExporter.to_proto_source(file) =~ "message Empty {}"
    end
  end

  describe "GIVEN the proto exporter WHEN a real service definition is exported end to end" do
    test "THEN a valid proto file is generated for the Support example domain" do
      [{name, source}] =
        Mix.Tasks.AshGrpc.Gen.Protos.generate_files(
          AshGrpc.Examples.SupportDesk,
          [AshGrpc.Support.V1.Tickets.Service]
        )

      assert name == "ash_grpc/support/v1/tickets.proto"
      assert source =~ ~s(syntax = "proto3";)
      assert source =~ "package ash_grpc.support.v1;"
      assert source =~ "service Tickets {"

      assert source =~
               "rpc StreamTickets (ash_grpc.support.v1.ListTicketsRequest)" <>
                 " returns (stream ash_grpc.support.v1.SubmitTicketReply);"

      assert source =~
               "rpc SyncTickets (stream ash_grpc.support.v1.SubmitTicketRequest)" <>
                 " returns (stream ash_grpc.support.v1.SubmitTicketReply);"
    end
  end
end
