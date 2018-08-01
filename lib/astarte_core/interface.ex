#
# Copyright (C) 2017-2018 Ispirata Srl
#
# This file is part of Astarte.
# Astarte is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Astarte is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with Astarte.  If not, see <http://www.gnu.org/licenses/>.
#

defmodule Astarte.Core.Interface do
  use Ecto.Schema
  import Ecto.Changeset

  alias Astarte.Core.CQLUtils
  alias Astarte.Core.Interface.Aggregation
  alias Astarte.Core.Interface.Ownership
  alias Astarte.Core.Interface.Type
  alias Astarte.Core.Interface
  alias Astarte.Core.Mapping

  @required_fields [
    :interface_name,
    :version_major,
    :version_minor,
    :type,
    :ownership,
  ]

  @permitted_fields [
    :aggregation,
    :quality,
    :aggregate,
    :description,
    :doc
    | @required_fields
  ]

  @primary_key false
  embedded_schema do
    field :interface_id, :binary
    field :name
    field :major_version, :integer
    field :minor_version, :integer
    field :type, Type
    field :ownership, Ownership
    field :aggregation, Aggregation, default: :individual
    field :description
    field :doc
    embeds_many :mappings, Mapping
    # Legacy
    field :quality, Ownership, virtual: true
    field :aggregate, :boolean, virtual: true
    # Different input naming
    field :interface_name, :string, virtual: true
    field :version_major, :integer, virtual: true
    field :version_minor, :integer, virtual: true
  end

  def changeset(%Interface{} = interface, params \\ %{}) do
    changeset =
      interface
      |> cast(params, @permitted_fields)
      |> handle_legacy_ownership()
      |> handle_legacy_aggregation()
      |> validate_required(@required_fields)
      |> validate_length(:interface_name, max: 128)
      |> validate_format(:interface_name, interface_name_regex())
      |> validate_number(:version_major, greater_than_or_equal_to: 0)
      |> validate_number(:version_minor, greater_than_or_equal_to: 0)
      |> validate_non_null_version()
      |> put_interface_id()
      |> normalize_fields()

    # We break the pipe because we need the changeset as argument to mapping_changeset
    changeset
    |> cast_embed(:mappings, required: true, with: mapping_changeset(changeset))
    |> validate_length(:mappings, min: 1, max: 1024)
    |> validate_mapping_uniqueness()
    |> validate_all_mappings_have_same_attributes()
    |> validate_all_mappings_have_same_prefix()
  end

  def interface_name_regex do
    ~r/^[a-zA-Z]+(\.[a-zA-Z0-9]+)*$/
  end

  defp handle_legacy_ownership(changeset) do
    if get_field(changeset, :ownership) do
      delete_change(changeset, :quality)
    else
      quality = get_change(changeset, :quality)

      changeset
      |> delete_change(:quality)
      |> put_change(:ownership, quality)
    end
  end

  defp handle_legacy_aggregation(changeset) do
    cond do
      get_change(changeset, :aggregation) ->
        delete_change(changeset, :aggregate)

      get_field(changeset, :aggregate) ->
        changeset
        |> delete_change(:aggregate)
        |> put_change(:aggregation, :object)

      true ->
        changeset
    end
  end

  defp mapping_changeset(%Ecto.Changeset{} = changeset) do
    name = get_field(changeset, :name)
    major = get_field(changeset, :major_version)
    minor = get_field(changeset, :minor_version)
    interface_id = get_field(changeset, :interface_id)
    type = get_field(changeset, :type)

    opts = [
      interface_name: name,
      interface_major: major,
      interface_minor: minor,
      interface_id: interface_id,
      interface_type: type
    ]

    fn type, params ->
      Mapping.changeset(type, params, opts)
    end
  end

  # Map the input fields to the expected internal fields
  defp normalize_fields(changeset) do
    name = get_field(changeset, :interface_name)
    major = get_field(changeset, :version_major)
    minor = get_field(changeset, :version_minor)

    changeset
    |> delete_change(:interface_name)
    |> delete_change(:version_major)
    |> delete_change(:version_minor)
    |> put_change(:name, name)
    |> put_change(:major_version, major)
    |> put_change(:minor_version, minor)
  end

  defp put_interface_id(changeset) do
    with {_, name} when is_binary(name) <- fetch_field(changeset, :interface_name),
         {_, major} when is_integer(major) <- fetch_field(changeset, :version_major) do
      interface_id = CQLUtils.interface_id(name, major)

      changeset
      |> put_change(:interface_id, interface_id)
    else
      _ ->
        changeset
    end
  end

  defp validate_non_null_version(changeset) do
    if get_field(changeset, :version_major) == 0 and get_field(changeset, :version_minor) == 0 do
      add_error(changeset, :version_minor, "must be > 0 if major_version is 0")
    else
      changeset
    end
  end

  defp validate_mapping_uniqueness(changeset) do
    mappings = get_field(changeset, :mappings, [])
    unique_count =
      Enum.uniq_by(mappings, fn mapping ->
        Mapping.normalize_endpoint(mapping.endpoint)
        |> String.downcase()
      end)
      |> Enum.count()

    if Enum.count(mappings) != unique_count do
      add_error(changeset, :mappings, "contain conflicting endpoints")
    else
      changeset
    end
  end

  defp validate_all_mappings_have_same_attributes(changeset) do
    mappings = get_field(changeset, :mappings, [])
    aggregation = get_field(changeset, :aggregation, [])

    if aggregation == :object and mappings != [] do
      %Mapping{
        retention: retention,
        reliability: reliability,
        expiry: expiry,
        allow_unset: allow_unset,
        explicit_timestamp: explicit_timestamp
      } = List.first(mappings)

      all_same_attributes =
        Enum.all?(mappings, fn mapping ->
          %Mapping{
            retention: mapping_retention,
            reliability: mapping_reliability,
            expiry: mapping_expiry,
            allow_unset: mapping_allow_unset,
            explicit_timestamp: mapping_explicit_timestamp
          } = mapping

          retention == mapping_retention and reliability == mapping_reliability and
            expiry == mapping_expiry and allow_unset == mapping_allow_unset and
            explicit_timestamp == mapping_explicit_timestamp
        end)

      unless all_same_attributes do
        add_error(changeset, :mappings, "contain conflicting attributes")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_all_mappings_have_same_prefix(changeset) do
    mappings = get_field(changeset, :mappings, [])
    aggregation = get_field(changeset, :aggregation, [])

    if aggregation == :object and mappings != [] do
      common_prefix =
        mappings
        |> List.first()
        |> Map.get(:endpoint)
        |> String.split("/")
        |> List.delete_at(-1)

      all_same_prefix =
        Enum.all?(mappings, fn mapping ->
          current_prefix =
            mapping
            |> Map.get(:endpoint)
            |> String.split("/")
            |> List.delete_at(-1)

          current_prefix == common_prefix
        end)

      unless all_same_prefix do
        add_error(changeset, :mappings, "must have the same prefix in endpoints")
      else
        changeset
      end
    else
      changeset
    end
  end

  defimpl Poison.Encoder, for: Interface do
    def encode(%Interface{} = interface, options) do
      %Interface{
        name: name,
        major_version: major_version,
        minor_version: minor_version,
        type: type,
        ownership: ownership,
        aggregation: aggregation,
        description: description,
        doc: doc,
        mappings: mappings
      } = interface

      %{
        interface_name: name,
        version_major: major_version,
        version_minor: minor_version,
        type: type,
        ownership: ownership,
        mappings: mappings
      }
      |> add_key_if_not_default(:aggregation, aggregation, :individual)
      |> add_key_if_not_nil(:description, description)
      |> add_key_if_not_nil(:doc, doc)
      |> Poison.Encoder.Map.encode(options)
    end

    defp add_key_if_not_default(encode_map, _key, default, default), do: encode_map

    defp add_key_if_not_default(encode_map, key, value, _default) do
      Map.put(encode_map, key, value)
    end

    defp add_key_if_not_nil(encode_map, _key, nil), do: encode_map

    defp add_key_if_not_nil(encode_map, key, value) do
      Map.put(encode_map, key, value)
    end
  end
end
