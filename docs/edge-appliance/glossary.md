---
---

# Edge Appliance Architecture Terminology

This is a living reference for the terminology used throughout the Edge Appliance architecture series.

The definitions describe the current architectural model. They are intentionally implementation-agnostic and may evolve as the model develops.

## Air-gapped Edge Appliance

An Edge Appliance designed to be deployed and operated in a Target Environment without relying on continuous connectivity to external systems.

The architecture must assume that artifacts, dependencies, lifecycle logic, configuration contracts, and verification information required for deployment are available within the air-gapped boundary or are explicitly guaranteed by the Target Environment.

## Layer

An independently owned architectural part of the product with its own lifecycle, pipeline, version, and responsibilities.

The current model uses three primary Layers:

- Infrastructure
- Platform
- Application

The exact boundaries are product-specific.

## Infrastructure Layer

The Layer responsible for the infrastructure capabilities required by the product.

Depending on the Edge Appliance, this may include hardware-facing software, operating system artifacts, provisioning assets, firmware, compute, storage, networking, or other infrastructure capabilities.

## Platform Layer

The Layer that provides the common runtime and platform capabilities consumed by the Application Layer.

Its exact contents depend on the product and may include orchestration, supporting services, policies, storage capabilities, networking behavior, security capabilities, or other shared platform functionality.

## Application Layer

The Layer that contains the product-specific application capabilities and the supporting artifacts required to run them on the Platform Layer.

## Layer Version

A specific, independently produced and identifiable version of a Layer.

A Layer Version is created by that Layer's lifecycle and can participate in one or more Product Versions as long as the relevant compatibility contracts remain satisfied.

## Product Version

A validated composition of specific Layer Versions.

A Product Version identifies which Infrastructure, Platform, and Application Layer Versions belong together and have been validated as a product.

A Product Version is a logical composition. It is not itself the physical deliverable.

## Product Package

The deliverable representation of a validated Product Version.

A Product Package preserves the exact composition of the Product Version and carries the information, artifacts, dependencies, lifecycle capabilities, and verification material required to operate that composition in an air-gapped Target Environment.

A Product Package does not define a new composition. It materializes one that has already been defined and validated.

## Layer Package

The deliverable representation of a Layer Version within a Product Package.

Conceptually, a Layer Package contains three parts:

- Layer Manifest
- Lifecycle Engine
- Payload

The physical packaging format is implementation-specific.

## Product Manifest

The product-level description of a Product Version inside the Product Package.

It identifies the Product Version, the Layer Versions that compose it, and their relationships.

It may also carry product-level metadata and configuration contracts required to understand and operate the package.

The Product Manifest is part of the immutable product definition. Operator-supplied deployment values are not changes to the Product Manifest.

## Layer Manifest

The description of a Layer Package.

It identifies the Layer and Layer Version and provides the metadata required to understand and operate the package.

Depending on the implementation, it may describe dependencies, prerequisites, compatibility information, configuration contracts, lifecycle capabilities, or other layer-specific metadata.

## Product Lifecycle Manager

The product-level component responsible for coordinating lifecycle operations across the Product Version.

It determines which Layer Lifecycle Engines need to be invoked, in what order, and under which conditions.

The Product Lifecycle Manager orchestrates the Layers but does not take ownership of their internal lifecycle implementation.

## Layer Lifecycle Engine

The layer-specific capability responsible for operating on a Layer Package and its Payload.

Deployment is one lifecycle operation, but a Layer Lifecycle Engine may also support validation, upgrade, rollback, recovery, removal, or other operations required by the product.

The exact implementation may be executable, declarative, or provided through another runtime mechanism.

## Payload

The artifacts that make up a Layer Version and are required to operate it.

Depending on the Layer, the Payload may include binaries, container images, operating system images, firmware, manifests, charts, policies, application artifacts, or other content.

## Lifecycle Environment

An environment used during the engineering lifecycle of a Layer Version or Product Version.

Examples may include development, integration, validation, testing, release, or other environments used to build and validate the product.

A Lifecycle Environment is not the deployment destination of the Edge Appliance.

## Target Environment

The environment in which a Product Version is deployed and operated.

The Target Environment provides deployment-specific resources, characteristics, and configuration values that are not part of the immutable Product Package but are required by its contracts.

When the deployment destination is isolated from external connectivity, it is an air-gapped Target Environment.

## Configuration Contract

The definition of which configuration values a product or Layer exposes, the constraints on those values, and who is allowed to supply or change them.

The product owns the Configuration Contract. A Target Environment or operator supplies only values that the contract permits.

## Product Configuration

Configuration that is part of the product definition and affects how the product is composed or behaves.

Product Configuration is controlled by the product lifecycle and is not freely modified by an operator at deployment time.

## Target Environment Configuration

Configuration values supplied for a specific deployment in a Target Environment.

These values may vary between installations without changing the Product Version, as long as they remain within the Configuration Contract defined by the product.

## Compatibility Contract

An explicit description of the assumptions one Layer makes about capabilities provided by another Layer.

Compatibility Contracts allow a Layer Version to be evaluated against a change in another Layer without automatically requiring every consuming Layer to be rebuilt.

## Deployment Dependency

Any artifact, capability, or prerequisite required to deploy a Product Version.

For an air-gapped Target Environment, each Deployment Dependency must either be included in the Product Package or explicitly guaranteed by the Target Environment.

## Dependency Closure

The property that all Deployment Dependencies required by a Product Version are either carried by the Product Package or are explicitly guaranteed by the Target Environment.

This property allows the Product Package to be self-contained without requiring the product architecture to become monolithic.
