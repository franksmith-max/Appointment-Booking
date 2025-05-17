;; Appointment Booking System Smart Contract
;; This contract allows users to book, view, modify, and cancel appointments with payment integration

(define-data-var contract-owner principal tx-sender)

;; Data structures
(define-map appointments
  { appointment-id: uint }
  {
    provider: principal,
    client: principal,
    date: uint,        ;; Unix timestamp for appointment date/time
    duration: uint,    ;; Duration in minutes
    status: (string-ascii 20),  ;; "booked", "completed", "cancelled", "rescheduled"
    service-type: (string-ascii 50),
    price: uint,       ;; Price in microSTX
    deposit-paid: uint,;; Amount of deposit paid
    payment-status: (string-ascii 20)  ;; "pending", "deposit-paid", "paid", "refunded"
  }
)

;; Keep track of all appointment IDs for a provider
(define-map provider-appointments
  { provider: principal }
  { appointment-ids: (list 100 uint) }
)

;; Keep track of all appointment IDs for a client
(define-map client-appointments
  { client: principal }
  { appointment-ids: (list 100 uint) }
)

;; Define a service price map
(define-map service-prices
  { provider: principal, service-type: (string-ascii 50) }
  { price: uint }  ;; Price in microSTX
)

;; Counter for appointment IDs
(define-data-var next-appointment-id uint u1)

;; Error codes
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_DATE (err u101))
(define-constant ERR_TIMESLOT_UNAVAILABLE (err u102))
(define-constant ERR_APPOINTMENT_NOT_FOUND (err u103))
(define-constant ERR_INVALID_OPERATION (err u104))
(define-constant ERR_ALREADY_BOOKED (err u105))
(define-constant ERR_INSUFFICIENT_PAYMENT (err u106))
(define-constant ERR_REFUND_FAILED (err u107))
(define-constant ERR_PAYMENT_FAILED (err u108))
(define-constant ERR_TOO_LATE_TO_MODIFY (err u109))
(define-constant ERR_INVALID_PRICE (err u110))

;; Read-only functions

;; Get appointment details by ID
(define-read-only (get-appointment (appointment-id uint))
  (match (map-get? appointments { appointment-id: appointment-id })
    appointment (ok appointment)
    ERR_APPOINTMENT_NOT_FOUND
  )
)

;; Get service price
(define-read-only (get-service-price (provider principal) (service-type (string-ascii 50)))
  (default-to { price: u0 } (map-get? service-prices { provider: provider, service-type: service-type }))
)

;; Get current block time
(define-read-only (get-current-time)
  (default-to u0 (get-block-info? time u0))
)

;; Helper function to check for appointment conflicts
(define-private (check-appointment-conflict (appt-id uint) (data { available: bool, new-date: uint, new-duration: uint }))
  (if (not (get available data))
    ;; If we already found a conflict, just return the data unchanged
    data
    ;; Otherwise check this appointment for conflicts
    (let (
      (appt (unwrap-panic (map-get? appointments { appointment-id: appt-id })))
      (appt-date (get date appt))
      (appt-duration (get duration appt))
      (appt-status (get status appt))
      (new-date (get new-date data))
      (new-duration (get new-duration data))
      (new-end-time (+ new-date (* new-duration u60)))
      (appt-end-time (+ appt-date (* appt-duration u60)))
    )
      (if (or (is-eq appt-status "cancelled") (is-eq appt-status "completed"))
        ;; If appointment is cancelled or completed, no conflict
        data
        ;; Check for time overlap
        (merge data { 
          available: (or 
                      ;; New appointment ends before current appointment starts
                      (< new-end-time appt-date)
                      ;; New appointment starts after current appointment ends
                      (> new-date appt-end-time)
                    )
        })
      )
    )
  )
)

;; Check if a time slot is available for a provider
(define-read-only (is-timeslot-available (provider principal) (date uint) (duration uint))
  (let (
    (provider-appts (default-to { appointment-ids: (list) } (map-get? provider-appointments { provider: provider })))
    (initial-data { available: true, new-date: date, new-duration: duration })
    (result (fold check-appointment-conflict (get appointment-ids provider-appts) initial-data))
  )
    (get available result)
  )
)

;; Get all appointments for a provider
(define-read-only (get-provider-appointments (provider principal))
  (match (map-get? provider-appointments { provider: provider })
    provider-appts (ok (get appointment-ids provider-appts))
    (ok (list))
  )
)

;; Get all appointments for a client
(define-read-only (get-client-appointments (client principal))
  (match (map-get? client-appointments { client: client })
    client-appts (ok (get appointment-ids client-appts))
    (ok (list))
  )
)

;; Public functions

;; Set service price (only for providers)
(define-public (set-service-price (service-type (string-ascii 50)) (price uint))
  (begin
    (asserts! (> price u0) ERR_INVALID_PRICE)
    (ok (map-set service-prices
      { provider: tx-sender, service-type: service-type }
      { price: price }
    ))
  )
)

;; Helper to add appointment to provider's list
(define-private (add-appointment-to-provider (provider principal) (appointment-id uint))
  (let (
    (current-appts (default-to { appointment-ids: (list) } (map-get? provider-appointments { provider: provider })))
    (updated-appts (unwrap-panic (as-max-len? (append (get appointment-ids current-appts) appointment-id) u100)))
  )
    (map-set provider-appointments
      { provider: provider }
      { appointment-ids: updated-appts }
    )
  )
)

;; Helper to add appointment to client's list
(define-private (add-appointment-to-client (client principal) (appointment-id uint))
  (let (
    (current-appts (default-to { appointment-ids: (list) } (map-get? client-appointments { client: client })))
    (updated-appts (unwrap-panic (as-max-len? (append (get appointment-ids current-appts) appointment-id) u100)))
  )
    (map-set client-appointments
      { client: client }
      { appointment-ids: updated-appts }
    )
  )
)

;; Create a new appointment with payment
(define-public (book-appointment 
  (provider principal) 
  (date uint) 
  (duration uint) 
  (service-type (string-ascii 50))
)
  (begin
    ;; Get necessary variables
    (let ((client tx-sender)
          (appointment-id (var-get next-appointment-id))
          (service-price (get price (get-service-price provider service-type)))
          (deposit-required (/ service-price u2))
          (current-time (get-current-time)))
        
        ;; Check preconditions
        (asserts! (> date current-time) ERR_INVALID_DATE)
        (asserts! (> service-price u0) ERR_INVALID_PRICE)
        (asserts! (is-timeslot-available provider date duration) ERR_TIMESLOT_UNAVAILABLE)
        
        ;; Process payment
        (asserts! (is-ok (stx-transfer? deposit-required tx-sender provider)) ERR_PAYMENT_FAILED)
            
        ;; Increment appointment ID counter
        (var-set next-appointment-id (+ appointment-id u1))
        
        ;; Store appointment
        (map-set appointments
          { appointment-id: appointment-id }
          {
            provider: provider,
            client: client,
            date: date,
            duration: duration,
            status: "booked",
            service-type: service-type,
            price: service-price,
            deposit-paid: deposit-required,
            payment-status: "deposit-paid"
          }
        )
        
        ;; Update provider and client appointment lists
        (add-appointment-to-provider provider appointment-id)
        (add-appointment-to-client client appointment-id)
        
        (ok appointment-id)
    )
  )
)

;; Pay remaining balance for appointment
(define-public (pay-appointment-balance (appointment-id uint))
  (begin
    (let (
      (appointment (unwrap! (map-get? appointments { appointment-id: appointment-id }) ERR_APPOINTMENT_NOT_FOUND))
      (client (get client appointment))
      (provider (get provider appointment))
      (price (get price appointment))
      (deposit-paid (get deposit-paid appointment))
      (status (get status appointment))
      (remaining-balance (- price deposit-paid))
    )
      ;; Verify that sender is the client
      (asserts! (is-eq tx-sender client) ERR_UNAUTHORIZED)
      
      ;; Check if the appointment is still active
      (asserts! (is-eq status "booked") ERR_INVALID_OPERATION)
      
      ;; Process remaining payment
      (asserts! (is-ok (stx-transfer? remaining-balance tx-sender provider)) ERR_PAYMENT_FAILED)
      
      ;; Update payment status
      (map-set appointments
        { appointment-id: appointment-id }
        (merge appointment { payment-status: "paid" })
      )
      
      (ok true)
    )
  )
)

;; Cancel an appointment
(define-public (cancel-appointment (appointment-id uint))
  (let (
    (appointment (unwrap! (map-get? appointments { appointment-id: appointment-id }) ERR_APPOINTMENT_NOT_FOUND))
    (provider (get provider appointment))
    (client (get client appointment))
    (status (get status appointment))
  )
    ;; Check if the appointment is in "booked" or "rescheduled" status
    (asserts! (or (is-eq status "booked") (is-eq status "rescheduled")) ERR_INVALID_OPERATION)
    
    ;; Verify that sender is either the client or provider
    (asserts! (or (is-eq tx-sender client) (is-eq tx-sender provider)) ERR_UNAUTHORIZED)
    
    ;; Update appointment status to "cancelled"
    (ok (map-set appointments
      { appointment-id: appointment-id }
      (merge appointment { status: "cancelled" })
    ))
  )
)

;; Process refund (if appointment is cancelled)
(define-public (process-refund (appointment-id uint))
  (begin
    (let (
      (appointment (unwrap! (map-get? appointments { appointment-id: appointment-id }) ERR_APPOINTMENT_NOT_FOUND))
      (client (get client appointment))
      (provider (get provider appointment))
      (deposit-paid (get deposit-paid appointment))
      (status (get status appointment))
      (current-time (get-current-time))
      (appointment-date (get date appointment))
      (refund-amount (if (> (- appointment-date current-time) (* u24 u60 u60))
                        deposit-paid  ;; Full refund if cancelled more than 24 hours in advance
                        (/ deposit-paid u2)))  ;; 50% refund if cancelled less than 24 hours in advance
    )
      ;; Verify that sender is the provider
      (asserts! (is-eq tx-sender provider) ERR_UNAUTHORIZED)
      
      ;; Check if the appointment is cancelled
      (asserts! (is-eq status "cancelled") ERR_INVALID_OPERATION)
      
      ;; Process refund
      (asserts! (is-ok (stx-transfer? refund-amount tx-sender client)) ERR_REFUND_FAILED)
      
      ;; Update payment status
      (map-set appointments
        { appointment-id: appointment-id }
        (merge appointment { payment-status: "refunded" })
      )
      
      (ok true)
    )
  )
)

;; Mark appointment as completed (only provider can do this)
(define-public (complete-appointment (appointment-id uint))
  (begin
    (let (
      (appointment (unwrap! (map-get? appointments { appointment-id: appointment-id }) ERR_APPOINTMENT_NOT_FOUND))
      (provider (get provider appointment))
      (client (get client appointment))
      (status (get status appointment))
      (payment-status (get payment-status appointment))
      (price (get price appointment))
      (deposit-paid (get deposit-paid appointment))
      (remaining-balance (- price deposit-paid))
    )
      ;; Check if the appointment is in "booked" or "rescheduled" status
      (asserts! (or (is-eq status "booked") (is-eq status "rescheduled")) ERR_INVALID_OPERATION)
      
      ;; Verify that sender is the provider
      (asserts! (is-eq tx-sender provider) ERR_UNAUTHORIZED)
      
      ;; Try to collect remaining balance if needed
      (if (and (> remaining-balance u0) (is-eq payment-status "deposit-paid"))
        (match (stx-transfer? remaining-balance client provider)
          success (begin
            ;; Update appointment status to "completed" and payment to "paid"
            (map-set appointments
              { appointment-id: appointment-id }
              (merge appointment { 
                status: "completed",
                payment-status: "paid" 
              })
            )
            (ok true)
          )
          ;; If automatic payment fails, just mark as completed but don't update payment status
          error (begin
            (map-set appointments
              { appointment-id: appointment-id }
              (merge appointment { status: "completed" })
            )
            (ok true)
          )
        )
        ;; If payment was already made or no remaining balance, just mark as completed
        (begin
          (map-set appointments
            { appointment-id: appointment-id }
            (merge appointment { status: "completed" })
          )
          (ok true)
        )
      )
    )
  )
)

;; Reschedule an appointment
(define-public (reschedule-appointment (appointment-id uint) (new-date uint))
  (let (
    (appointment (unwrap! (map-get? appointments { appointment-id: appointment-id }) ERR_APPOINTMENT_NOT_FOUND))
    (provider (get provider appointment))
    (client (get client appointment))
    (current-date (get date appointment))
    (duration (get duration appointment))
    (status (get status appointment))
    (current-time (get-current-time))
  )
    ;; Check if the appointment is in "booked" status
    (asserts! (is-eq status "booked") ERR_INVALID_OPERATION)
    
    ;; Verify that sender is the client
    (asserts! (is-eq tx-sender client) ERR_UNAUTHORIZED)
    
    ;; Check if new date is in the future
    (asserts! (> new-date current-time) ERR_INVALID_DATE)
    
    ;; Check if it's not too late to modify (at least 12 hours before)
    (asserts! (> (- current-date current-time) (* u12 u60 u60)) ERR_TOO_LATE_TO_MODIFY)
    
    ;; Check if the new timeslot is available
    (asserts! (is-timeslot-available provider new-date duration) ERR_TIMESLOT_UNAVAILABLE)
    
    ;; Update appointment with new date and mark as rescheduled
    (ok (map-set appointments
      { appointment-id: appointment-id }
      (merge appointment { 
        date: new-date, 
        status: "rescheduled" 
      })
    ))
  )
)

;; Modify appointment service or duration
(define-public (modify-appointment 
  (appointment-id uint) 
  (new-duration (optional uint))
  (new-service-type (optional (string-ascii 50)))
)
  (begin
    (let (
      (appointment (unwrap! (map-get? appointments { appointment-id: appointment-id }) ERR_APPOINTMENT_NOT_FOUND))
      (provider (get provider appointment))
      (client (get client appointment))
      (current-date (get date appointment))
      (current-duration (get duration appointment))
      (current-service-type (get service-type appointment))
      (current-price (get price appointment))
      (deposit-paid (get deposit-paid appointment))
      (status (get status appointment))
      (current-time (get-current-time))
      
      ;; Determine new values (use current if not provided)
      (final-duration (default-to current-duration new-duration))
      (final-service-type (default-to current-service-type new-service-type))
      
      ;; Check new price if service changed
      (new-price (if (is-some new-service-type)
                    (get price (get-service-price provider (unwrap! new-service-type ERR_INVALID_OPERATION)))
                    current-price))
      
      ;; Calculate price difference (if any)
      (price-difference (- new-price current-price))
    )
      ;; Check if the appointment is in "booked" status
      (asserts! (is-eq status "booked") ERR_INVALID_OPERATION)
      
      ;; Verify that sender is the client
      (asserts! (is-eq tx-sender client) ERR_UNAUTHORIZED)
      
      ;; Check if it's not too late to modify (at least 12 hours before)
      (asserts! (> (- current-date current-time) (* u12 u60 u60)) ERR_TOO_LATE_TO_MODIFY)
      
      ;; Check if the timeslot is still available with new duration
      (asserts! (or (is-eq final-duration current-duration) 
                   (is-timeslot-available provider current-date final-duration)) 
                ERR_TIMESLOT_UNAVAILABLE)
      
      ;; If price increased, request additional deposit
      (if (> price-difference u0)
        (begin
          ;; Process additional deposit payment
          (asserts! (is-ok (stx-transfer? (/ price-difference u2) tx-sender provider)) ERR_PAYMENT_FAILED)
          
          ;; Update appointment with new details
          (map-set appointments
            { appointment-id: appointment-id }
            (merge appointment { 
              duration: final-duration, 
              service-type: final-service-type,
              price: new-price,
              deposit-paid: (+ deposit-paid (/ price-difference u2))
            })
          )
          (ok true)
        )
        ;; If same or lower price, just update
        (begin
          (map-set appointments
            { appointment-id: appointment-id }
            (merge appointment { 
              duration: final-duration, 
              service-type: final-service-type,
              price: new-price
            })
          )
          (ok true)
        )
      )
    )
  )
)

;; Contract initialization
(define-public (initialize-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_UNAUTHORIZED)
    (ok true)
  )
)