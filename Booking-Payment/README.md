# Appointment Booking System Smart Contract

## Overview

This smart contract implements a decentralized appointment booking system on the Stacks blockchain. It allows service providers to offer appointments for various services, and clients to book, modify, and cancel these appointments with integrated payment handling.

## Features

- **Appointment Management**: Book, reschedule, modify, and cancel appointments
- **Payment Integration**: Process deposits, full payments, and refunds using STX tokens
- **Service Pricing**: Providers can set and update prices for different service types
- **Advanced Booking Rules**:
  - Automatic conflict detection for time slots
  - Automated refund policies based on cancellation time
  - Flexible appointment modification with price adjustment

## Functions

### Read-Only Functions

| Function | Description |
|----------|-------------|
| `get-appointment` | Retrieve details of a specific appointment by ID |
| `get-service-price` | Get the price for a specific service offered by a provider |
| `is-timeslot-available` | Check if a time slot is available for a provider |
| `get-provider-appointments` | Get all appointment IDs for a provider |
| `get-client-appointments` | Get all appointment IDs for a client |

### Public Functions

| Function | Description |
|----------|-------------|
| `set-service-price` | Allow providers to set prices for their services |
| `book-appointment` | Book a new appointment with a 50% deposit |
| `pay-appointment-balance` | Pay the remaining balance for an appointment |
| `cancel-appointment` | Cancel a booked or rescheduled appointment |
| `process-refund` | Process refund for a cancelled appointment (provider only) |
| `complete-appointment` | Mark an appointment as completed (provider only) |
| `reschedule-appointment` | Change the date of an existing appointment |
| `modify-appointment` | Change the service type or duration of an appointment |
| `initialize-contract` | Initialize the contract (owner only) |

## Data Structures

The contract uses several maps to store appointment data:

- `appointments`: Stores all appointment details indexed by appointment ID
- `provider-appointments`: Maps providers to their list of appointment IDs
- `client-appointments`: Maps clients to their list of appointment IDs
- `service-prices`: Stores service prices for each provider and service type

## Error Codes

| Code | Description |
|------|-------------|
| 100 | Unauthorized access |
| 101 | Invalid date (must be in the future) |
| 102 | Time slot unavailable (conflict with existing appointment) |
| 103 | Appointment not found |
| 104 | Invalid operation for current appointment status |
| 105 | Appointment already booked |
| 106 | Insufficient payment |
| 107 | Refund failed |
| 108 | Payment failed |
| 109 | Too late to modify (less than 12 hours before appointment) |
| 110 | Invalid price |

## Payment Flow

1. **Booking**: Client pays 50% deposit when booking
2. **Balance Payment**: Client can pay remaining balance anytime before appointment
3. **Cancellation**: 
   - Full refund if cancelled >24 hours before appointment
   - 50% refund if cancelled <24 hours before appointment
4. **Completion**: Provider can automatically collect remaining balance when marking as completed

## Usage Examples

### For Service Providers

```clarity
;; Set price for a service
(contract-call? .appointment-booking set-service-price "Haircut" u50000000)  ;; 50 STX

;; Mark appointment as completed
(contract-call? .appointment-booking complete-appointment u1)

;; Process refund for cancelled appointment
(contract-call? .appointment-booking process-refund u2)
```

### For Clients

```clarity
;; Book a new appointment
(contract-call? .appointment-booking book-appointment 
  'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM 
  u1683900000  ;; Unix timestamp
  u60          ;; 60 minutes duration
  "Haircut"    ;; Service type
)

;; Pay remaining balance
(contract-call? .appointment-booking pay-appointment-balance u1)

;; Reschedule an appointment
(contract-call? .appointment-booking reschedule-appointment u1 u1684000000)

;; Modify appointment service or duration
(contract-call? .appointment-booking modify-appointment u1 (some u90) (some "Premium Haircut"))

;; Cancel an appointment
(contract-call? .appointment-booking cancel-appointment u1)
```

## Deployment Instructions

1. Deploy the contract to the Stacks blockchain
2. Call `initialize-contract` function as the contract deployer
3. Service providers can start setting prices for their services
4. Clients can begin booking appointments

## Security Considerations

- Only the appointment client can reschedule or modify appointments
- Only the provider can mark appointments as completed or process refunds
- Appointment modifications must be made at least 12 hours before the scheduled time
- The contract implements proper authorization checks for all operations