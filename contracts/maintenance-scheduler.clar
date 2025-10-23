;; Maintenance Scheduler Smart Contract
;; Schedules street maintenance with resource optimization and completion tracking

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-status (err u103))
(define-constant err-already-assigned (err u104))
(define-constant err-not-assigned (err u105))
(define-constant err-invalid-priority (err u106))

;; Work order statuses
(define-constant status-pending u1)
(define-constant status-scheduled u2)
(define-constant status-in-progress u3)
(define-constant status-completed u4)
(define-constant status-verified u5)
(define-constant status-cancelled u6)

;; Priority levels
(define-constant priority-emergency u1)
(define-constant priority-high u2)
(define-constant priority-medium u3)
(define-constant priority-low u4)

;; Data Variables
(define-data-var work-order-counter uint u0)
(define-data-var crew-counter uint u0)
(define-data-var total-completed uint u0)
(define-data-var total-verified uint u0)

;; Data Maps
(define-map work-orders
  { order-id: uint }
  {
    task-type: (string-ascii 50),
    location: (string-ascii 100),
    description: (string-utf8 300),
    priority: uint,
    status: uint,
    created-by: principal,
    created-at: uint,
    scheduled-date: (optional uint),
    assigned-crew: (optional uint),
    started-at: (optional uint),
    completed-at: (optional uint),
    verified-by: (optional principal),
    estimated-cost: uint,
    actual-cost: (optional uint),
    notes: (string-utf8 200)
  }
)

(define-map crews
  { crew-id: uint }
  {
    crew-name: (string-ascii 50),
    supervisor: principal,
    size: uint,
    specialization: (string-ascii 50),
    active: bool,
    current-assignment: (optional uint)
  }
)

(define-map equipment
  { equipment-id: uint }
  {
    equipment-name: (string-ascii 50),
    equipment-type: (string-ascii 30),
    available: bool,
    assigned-to-order: (optional uint)
  }
)

(define-map authorized-supervisors principal bool)

(define-map crew-stats
  { crew-id: uint }
  { tasks-completed: uint, total-hours: uint, efficiency-rating: uint }
)

(define-map location-history
  { location: (string-ascii 100) }
  { maintenance-count: uint, last-service: uint }
)

;; Authorization Functions
(define-public (add-supervisor (supervisor principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (ok (map-set authorized-supervisors supervisor true))
  )
)

(define-public (remove-supervisor (supervisor principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (ok (map-delete authorized-supervisors supervisor))
  )
)

(define-read-only (is-supervisor (supervisor principal))
  (default-to false (map-get? authorized-supervisors supervisor))
)

;; Work Order Functions
(define-public (create-work-order
  (task-type (string-ascii 50))
  (location (string-ascii 100))
  (description (string-utf8 300))
  (priority uint)
  (estimated-cost uint))
  (let
    (
      (order-id (+ (var-get work-order-counter) u1))
      (location-hist (default-to
        { maintenance-count: u0, last-service: u0 }
        (map-get? location-history { location: location })))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-supervisor tx-sender)) err-unauthorized)
    (asserts! (<= priority priority-low) err-invalid-priority)
    
    (map-set work-orders
      { order-id: order-id }
      {
        task-type: task-type,
        location: location,
        description: description,
        priority: priority,
        status: status-pending,
        created-by: tx-sender,
        created-at: stacks-block-height,
        scheduled-date: none,
        assigned-crew: none,
        started-at: none,
        completed-at: none,
        verified-by: none,
        estimated-cost: estimated-cost,
        actual-cost: none,
        notes: u""
      }
    )
    
    (map-set location-history
      { location: location }
      {
        maintenance-count: (+ (get maintenance-count location-hist) u1),
        last-service: stacks-block-height
      }
    )
    
    (var-set work-order-counter order-id)
    (ok order-id)
  )
)

(define-public (assign-crew (order-id uint) (crew-id uint) (scheduled-date uint))
  (let
    (
      (order (unwrap! (map-get? work-orders { order-id: order-id }) err-not-found))
      (crew (unwrap! (map-get? crews { crew-id: crew-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-supervisor tx-sender)) err-unauthorized)
    (asserts! (get active crew) err-invalid-status)
    (asserts! (is-eq (get status order) status-pending) err-invalid-status)
    
    (map-set work-orders
      { order-id: order-id }
      (merge order {
        status: status-scheduled,
        assigned-crew: (some crew-id),
        scheduled-date: (some scheduled-date)
      })
    )
    
    (map-set crews
      { crew-id: crew-id }
      (merge crew { current-assignment: (some order-id) })
    )
    
    (ok true)
  )
)

(define-public (start-work (order-id uint))
  (let
    (
      (order (unwrap! (map-get? work-orders { order-id: order-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-supervisor tx-sender)) err-unauthorized)
    (asserts! (is-eq (get status order) status-scheduled) err-invalid-status)
    
    (map-set work-orders
      { order-id: order-id }
      (merge order {
        status: status-in-progress,
        started-at: (some stacks-block-height)
      })
    )
    
    (ok true)
  )
)

(define-public (complete-work (order-id uint) (actual-cost uint) (notes (string-utf8 200)))
  (let
    (
      (order (unwrap! (map-get? work-orders { order-id: order-id }) err-not-found))
      (crew-id (unwrap! (get assigned-crew order) err-not-assigned))
      (crew-statistics (default-to
        { tasks-completed: u0, total-hours: u0, efficiency-rating: u0 }
        (map-get? crew-stats { crew-id: crew-id })))
      (crew-data (unwrap! (map-get? crews { crew-id: crew-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-supervisor tx-sender)) err-unauthorized)
    (asserts! (is-eq (get status order) status-in-progress) err-invalid-status)
    
    (map-set work-orders
      { order-id: order-id }
      (merge order {
        status: status-completed,
        completed-at: (some stacks-block-height),
        actual-cost: (some actual-cost),
        notes: notes
      })
    )
    
    (map-set crew-stats
      { crew-id: crew-id }
      {
        tasks-completed: (+ (get tasks-completed crew-statistics) u1),
        total-hours: (get total-hours crew-statistics),
        efficiency-rating: (get efficiency-rating crew-statistics)
      }
    )
    
    (map-set crews
      { crew-id: crew-id }
      (merge crew-data { current-assignment: none })
    )
    
    (var-set total-completed (+ (var-get total-completed) u1))
    (ok true)
  )
)

(define-public (verify-work (order-id uint))
  (let
    (
      (order (unwrap! (map-get? work-orders { order-id: order-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-supervisor tx-sender)) err-unauthorized)
    (asserts! (is-eq (get status order) status-completed) err-invalid-status)
    
    (map-set work-orders
      { order-id: order-id }
      (merge order {
        status: status-verified,
        verified-by: (some tx-sender)
      })
    )
    
    (var-set total-verified (+ (var-get total-verified) u1))
    (ok true)
  )
)

(define-public (cancel-order (order-id uint) (reason (string-utf8 200)))
  (let
    (
      (order (unwrap! (map-get? work-orders { order-id: order-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set work-orders
      { order-id: order-id }
      (merge order {
        status: status-cancelled,
        notes: reason
      })
    )
    
    (ok true)
  )
)

;; Crew Management Functions
(define-public (register-crew
  (crew-name (string-ascii 50))
  (supervisor principal)
  (size uint)
  (specialization (string-ascii 50)))
  (let
    (
      (crew-id (+ (var-get crew-counter) u1))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set crews
      { crew-id: crew-id }
      {
        crew-name: crew-name,
        supervisor: supervisor,
        size: size,
        specialization: specialization,
        active: true,
        current-assignment: none
      }
    )
    
    (map-set crew-stats
      { crew-id: crew-id }
      { tasks-completed: u0, total-hours: u0, efficiency-rating: u100 }
    )
    
    (var-set crew-counter crew-id)
    (ok crew-id)
  )
)

(define-public (deactivate-crew (crew-id uint))
  (let
    (
      (crew (unwrap! (map-get? crews { crew-id: crew-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set crews
      { crew-id: crew-id }
      (merge crew { active: false })
    )
    
    (ok true)
  )
)

;; Read-Only Functions
(define-read-only (get-work-order (order-id uint))
  (map-get? work-orders { order-id: order-id })
)

(define-read-only (get-crew (crew-id uint))
  (map-get? crews { crew-id: crew-id })
)

(define-read-only (get-crew-stats (crew-id uint))
  (map-get? crew-stats { crew-id: crew-id })
)

(define-read-only (get-location-history (location (string-ascii 100)))
  (map-get? location-history { location: location })
)

(define-read-only (get-total-completed)
  (ok (var-get total-completed))
)

(define-read-only (get-total-verified)
  (ok (var-get total-verified))
)

(define-read-only (get-work-order-counter)
  (ok (var-get work-order-counter))
)

(define-read-only (is-order-completed (order-id uint))
  (match (map-get? work-orders { order-id: order-id })
    order (ok (or
      (is-eq (get status order) status-completed)
      (is-eq (get status order) status-verified)
    ))
    err-not-found
  )
)

;; Initialize contract owner as authorized supervisor
(map-set authorized-supervisors contract-owner true)
