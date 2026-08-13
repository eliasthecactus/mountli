package sddl

import (
	"testing"
)

func TestParseSIDBinary(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		data    []byte
		want    string
		wantErr bool
	}{
		{
			name:    "Invalid data - too short",
			data:    []byte{0x01, 0x02}, // Not enough bytes for a valid SID
			want:    "",
			wantErr: true,
		},
		{
			name:    "Invalid data - nil",
			data:    nil,
			want:    "",
			wantErr: true,
		},
		{
			name: "Invalid data - mismatched length for sub-authorities",
			data: []byte{
				0x01,                               // Revision
				0x02,                               // SubAuthorityCount (claims 2 but only has data for 1)
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority
				0x01, 0x00, 0x00, 0x00, // One SubAuthority only
			},
			want:    "",
			wantErr: true,
		},
		{
			name: "Valid minimal SID",
			data: []byte{
				0x01,                               // Revision
				0x01,                               // SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority (NT Authority)
				0x01, 0x00, 0x00, 0x00, // SubAuthority[0] = 1 (DIALUP)
			},
			want:    "DU", // Well-known SID for DIALUP
			wantErr: false,
		},
		{
			name: "Valid SID with multiple authorities",
			data: []byte{
				0x01,                               // Revision
				0x02,                               // SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority (NT Authority)
				0x20, 0x00, 0x00, 0x00, // SubAuthority[0] = 32 (BUILTIN)
				0x20, 0x02, 0x00, 0x00, // SubAuthority[1] = 544 (Administrators)
			},
			want:    "BA", // Well-known SID for BUILTIN\Administrators
			wantErr: false,
		},
		{
			name: "Non-well-known SID",
			data: []byte{
				0x01,                               // Revision
				0x05,                               // SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority
				0x21, 0x00, 0x00, 0x00, // SubAuthority[0]
				0x22, 0x00, 0x00, 0x00, // SubAuthority[1]
				0x23, 0x00, 0x00, 0x00, // SubAuthority[2]
				0x24, 0x00, 0x00, 0x00, // SubAuthority[3]
				0x25, 0x00, 0x00, 0x00, // SubAuthority[4]
			},
			want:    "S-1-5-33-34-35-36-37", // Regular SID format
			wantErr: false,
		},
		{
			name: "Well-known NT AUTHORITY\\SYSTEM SID",
			data: []byte{
				0x01,                               // Revision
				0x01,                               // SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority (NT Authority)
				0x12, 0x00, 0x00, 0x00, // SubAuthority[0] = 18 (SYSTEM)
			},
			want:    "SY", // Well-known SID for Local System
			wantErr: false,
		},
		{
			name: "Well-known Everyone SID",
			data: []byte{
				0x01,                               // Revision
				0x01,                               // SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // World Authority
				0x00, 0x00, 0x00, 0x00, // SubAuthority[0] = 0
			},
			want:    "WD", // Well-known SID for Everyone
			wantErr: false,
		},
		{
			name: "Maximum sub-authorities",
			data: []byte{
				0x01,                               // Revision
				0x0F,                               // SubAuthorityCount (15 is max)
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority
				0x01, 0x00, 0x00, 0x00, // SubAuthority[0]
				0x02, 0x00, 0x00, 0x00,
				0x03, 0x00, 0x00, 0x00,
				0x04, 0x00, 0x00, 0x00,
				0x05, 0x00, 0x00, 0x00,
				0x06, 0x00, 0x00, 0x00,
				0x07, 0x00, 0x00, 0x00,
				0x08, 0x00, 0x00, 0x00,
				0x09, 0x00, 0x00, 0x00,
				0x0A, 0x00, 0x00, 0x00,
				0x0B, 0x00, 0x00, 0x00,
				0x0C, 0x00, 0x00, 0x00,
				0x0D, 0x00, 0x00, 0x00,
				0x0E, 0x00, 0x00, 0x00,
				0x0F, 0x00, 0x00, 0x00,
			},
			want:    "S-1-5-1-2-3-4-5-6-7-8-9-10-11-12-13-14-15",
			wantErr: false,
		},
		{
			name: "Too many sub-authorities",
			data: []byte{
				0x01,                               // Revision
				0x10,                               // SubAuthorityCount (16 is too many)
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // IdentifierAuthority
				0x01, 0x00, 0x00, 0x00, // SubAuthority data...
			},
			want:    "",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			sid, err := parseSIDBinary(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Errorf("parseSIDBinary() error = %v, wantErr %v", err, tt.wantErr)
				}
				if sid != nil {
					t.Errorf("parseSIDBinary() sid = %#v, want nil", sid)
				}
				return
			}

			if err != nil {
				t.Errorf("parseSIDBinary() error = %v, wantErr %v", err, tt.wantErr)
			}

			if sid == nil {
				t.Errorf("parseSIDBinary() sid = nil, want non-nil, wantErr %v", tt.wantErr)
				return
			}

			if sidStr := sid.String(); sidStr != tt.want {
				t.Errorf("parseSIDBinary() = %v, want %v, (sid = %#v)", sidStr, tt.want, sid)
			}
		})
	}
}

func TestParseACEBinary(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		data    []byte
		want    string
		wantErr bool
	}{
		{
			name:    "Invalid data - too short",
			data:    []byte{0x00, 0x00, 0x14, 0x00}, // Only header size, no mask or SID
			want:    "",
			wantErr: true,
		},
		{
			name: "Invalid data - mismatched size",
			data: []byte{
				0x00,       // Type
				0x00,       // Flags
				0xFF, 0x00, // Size (larger than actual data)
				0x00, 0x00, 0x00, 0x00, // Mask
				// Minimal SID
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00,
			},
			want:    "",
			wantErr: true,
		},
		{
			name: "Basic Allow ACE",
			data: []byte{
				// ACE Header
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x00,       // Flags (none)
				0x14, 0x00, // Size (20 bytes)
				// Access mask
				0xFF, 0x01, 0x1F, 0x00, // 0x1F01FF - Full Access
				// SID (SYSTEM)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00,
			},
			want:    "(A;;FA;;;SY)",
			wantErr: false,
		},
		{
			name: "Basic Deny ACE",
			data: []byte{
				0x01,       // Type (ACCESS_DENIED_ACE_TYPE)
				0x00,       // Flags
				0x14, 0x00, // Size
				0x89, 0x00, 0x12, 0x00, // 0x120089 - File Read
				// SID (Everyone)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
				0x00, 0x00, 0x00, 0x00,
			},
			want:    "(D;;FR;;;WD)",
			wantErr: false,
		},
		{
			name: "Audit ACE",
			data: []byte{
				0x02,       // Type (SYSTEM_AUDIT_ACE_TYPE)
				0x00,       // Flags
				0x18, 0x00, // Size
				0x16, 0x01, 0x12, 0x00, // 0x00120116 - File Write
				// SID (BUILTIN\Administrators)
				0x01, 0x02,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x20, 0x00, 0x00, 0x00,
				0x20, 0x02, 0x00, 0x00,
			},
			want:    "(AU;;FW;;;BA)",
			wantErr: false,
		},
		{
			name: "ACE with inheritance flags",
			data: []byte{
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x0B,       // Flags (CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE | INHERIT_ONLY_ACE)
				0x14, 0x00, // Size
				0xA9, 0x00, 0x12, 0x00, // 0x1200A9 - Read and Execute Access
				// SID (Authenticated Users)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x0B, 0x00, 0x00, 0x00,
			},
			want:    "(A;OICIIO;CCSWWPLORCSY;;;AU)",
			wantErr: false,
		},
		{
			name: "ACE with custom access mask",
			data: []byte{
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x00,       // Flags
				0x14, 0x00, // Size
				0x34, 0x12, 0x56, 0x78, // Custom access mask
				// SID (SYSTEM)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00,
			},
			want:    "(A;;0x78561234;;;SY)",
			wantErr: false,
		},
		{
			name: "ACE with inherited flag",
			data: []byte{
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x10,       // Flags (INHERITED_ACE)
				0x18, 0x00, // Size
				0x89, 0x00, 0x12, 0x00, // File Read
				// SID (BUILTIN\Users)
				0x01, 0x02,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x20, 0x00, 0x00, 0x00,
				0x21, 0x02, 0x00, 0x00,
			},
			want:    "(A;ID;FR;;;BU)",
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			ace, err := parseACEBinary(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Errorf("parseACEBinary() expected error, got nil")
				}
				if ace != nil {
					t.Errorf("parseACEBinary() expected nil, got %v", ace)
				}
				return
			}

			if err != nil {
				t.Errorf("parseACEBinary() error = %v, expected nil", err)
				return
			}

			if ace == nil {
				t.Errorf("parseACEBinary() expected non-nil, got nil")
				return
			}

			if aceStr := ace.String(); aceStr != tt.want {
				t.Errorf("parseACEBinary() = %v, want %v", aceStr, tt.want)
			}
		})
	}
}

func TestParseACLBinary(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		data    []byte
		aclType string
		control uint16
		want    *acl
		wantStr string
		wantErr bool
	}{
		{
			name:    "Invalid data - too short",
			data:    []byte{0x02, 0x00}, // Not enough bytes for ACL header
			aclType: "D",
			control: 0,
			wantStr: "",
			wantErr: true,
		},
		{
			name: "Invalid data - size mismatch",
			data: []byte{
				0x02,       // Revision
				0x00,       // Sbz1
				0xFF, 0x00, // Size (too large)
				0x01, 0x00, // AceCount
				0x00, 0x00, // Sbz2
			},
			aclType: "D",
			control: 0,
			wantStr: "",
			wantErr: true,
		},
		{
			name: "Empty ACL",
			data: []byte{
				0x02,       // Revision
				0x00,       // Sbz1
				0x08, 0x00, // Size (8 bytes - just header)
				0x00, 0x00, // AceCount
				0x00, 0x00, // Sbz2
			},
			aclType: "D",
			control: 0,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x8,
				sbz2:        0,
				aclType:     "D",
				control:     0,
				aces:        nil,
			},
			wantStr: "",
			wantErr: false,
		},
		{
			name: "Protected empty ACL",
			data: []byte{
				0x02,       // Revision
				0x00,       // Sbz1
				0x08, 0x00, // Size
				0x00, 0x00, // AceCount
				0x00, 0x00, // Sbz2
			},
			aclType: "D",
			control: seDACLProtected,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x8,
				sbz2:        0,
				aclType:     "D",
				control:     seDACLProtected,
			},
			wantStr: "P",
			wantErr: false,
		},
		{
			name: "Auto-inherited empty ACL",
			data: []byte{
				0x02,       // Revision
				0x00,       // Sbz1
				0x08, 0x00, // Size
				0x00, 0x00, // AceCount
				0x00, 0x00, // Sbz2
			},
			aclType: "D",
			control: seDACLAutoInherited,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x8,
				sbz2:        0,
				aclType:     "D",
				control:     seDACLAutoInherited,
			},
			wantStr: "AI",
			wantErr: false,
		},
		{
			name: "Protected and auto-inherited empty ACL",
			data: []byte{
				0x02,       // Revision
				0x00,       // Sbz1
				0x08, 0x00, // Size
				0x00, 0x00, // AceCount
				0x00, 0x00, // Sbz2
			},
			aclType: "D",
			control: seDACLProtected | seDACLAutoInherited,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x8,
				sbz2:        0,
				aclType:     "D",
				control:     seDACLProtected | seDACLAutoInherited,
			},
			wantStr: "PAI",
			wantErr: false,
		},
		{
			name: "ACL with one ACE",
			data: []byte{
				// ACL Header
				0x02,       // Revision
				0x00,       // Sbz1
				0x1C, 0x00, // Size (28 bytes = 8 header + 20 ACE)
				0x01, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// ACE
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x00,       // Flags
				0x14, 0x00, // Size (20 bytes)
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				// SID (SYSTEM)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority (NT Authority)
				0x12, 0x00, 0x00, 0x00, // SubAuthority (SYSTEM)
			},
			aclType: "D",
			control: 0,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x1C, // 28 bytes = 8 header + 20 ACE
				aceCount:    1,
				sbz2:        0,
				aclType:     "D",
				control:     0,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  0,
							aceFlags: 0,
							aceSize:  0x14, // 20 Bytes
						},
						accessMask: 0x001F01FF, // Full Access
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,              // NT Authority
							subAuthority:        []uint32{0x12}, // SYSTEM
						},
					},
				},
			},
			wantStr: "(A;;FA;;;SY)",
			wantErr: false,
		},
		{
			name: "ACL with multiple ACEs",
			data: []byte{
				// ACL Header
				0x02,       // Revision
				0x00,       // Sbz1
				0x38, 0x00, // Size (56 bytes = 8 header + 20 first ACE + 28 second ACE)
				0x02, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// First ACE - Allow System Full Access
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x00,       // Flags
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				0x01, 0x01, // SID - Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authoruty
				0x12, 0x00, 0x00, 0x00, // SubAuthority - SYSTEM
				// Second ACE - Allow Administrators Read
				0x00,       // Type
				0x00,       // Flags
				0x18, 0x00, // Size (24 bytes - larger to accommodate full Administrators SID)
				0x89, 0x00, 0x12, 0x00, // Access mask (File Read)
				0x01, 0x02, // SID: Rev=1, Count=2
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority (NT Authority)
				0x20, 0x00, 0x00, 0x00, // SubAuth1 = 32 (BUILTIN)
				0x20, 0x02, 0x00, 0x00, // SubAuth2 = 544 (Administrators)
			},
			aclType: "D",
			control: 0,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x38, // 56 bytes = 8 header + 20 first ACE + 28 second ACE
				aceCount:    2,
				sbz2:        0,
				aclType:     "D",
				control:     0,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  0,
							aceFlags: 0,
							aceSize:  0x14, // 20 Bytes
						},
						accessMask: 0x001F01FF, // Full Access
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{0x12},
						},
					},
					{
						header: &aceHeader{
							aceType:  0,
							aceFlags: 0,
							aceSize:  0x18, // 24 Bytes
						},
						accessMask: 0x00120089, // File Read
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,                      // NT Authority
							subAuthority:        []uint32{0x20, 0x0220}, // BUILTIN, Administrators
						},
					},
				},
			},
			wantStr: "(A;;FA;;;SY)(A;;FR;;;BA)",
			wantErr: false,
		},
		{
			name: "SACL with audit ACEs",
			data: []byte{
				// ACL Header
				0x02,       // Revision
				0x00,       // Sbz1
				0x28, 0x00, // Size (40 bytes = 8 header + 2 ACEs of 16 bytes each)
				0x02, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// First ACE - Audit System Success
				0x02,       // Type (SYSTEM_AUDIT_ACE_TYPE)
				0x40,       // Flags (SUCCESSFUL_ACCESS_ACE)
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00, // SYSTEM
				// Second ACE - Audit System Failure
				0x02,       // Type (SYSTEM_AUDIT_ACE_TYPE)
				0x80,       // Flags (FAILED_ACCESS_ACE)
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00, // SYSTEM
			},
			aclType: "S",
			control: seSACLPresent,
			want: &acl{
				aclRevision: 0x02,
				sbzl:        0,
				aclSize:     0x28, // 40 bytes = 8 header + 2 ACEs of 16 bytes each
				aceCount:    2,
				sbz2:        0,
				aclType:     "S",
				control:     seSACLPresent,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  2,    // SYSTEM_AUDIT_ACE_TYPE
							aceFlags: 0x40, // SUCCESSFUL_ACCESS_ACE
							aceSize:  0x14, // 20 Bytes
						},
						accessMask: 0x001F01FF, // Full Access
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,              // NT Authority
							subAuthority:        []uint32{0x12}, // SYSTEM
						},
					},
					{
						header: &aceHeader{
							aceType:  2,    // SYSTEM_AUDIT_ACE_TYPE
							aceFlags: 0x80, // FAILED_ACCESS_ACE
							aceSize:  0x14, // 20 Bytes
						},
						accessMask: 0x001F01FF, // Full Access
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,              // NT Authority
							subAuthority:        []uint32{0x12}, // SYSTEM
						},
					},
				},
			},
			wantStr: "(AU;SA;FA;;;SY)(AU;FA;FA;;;SY)",
			wantErr: false,
		}}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			acl, err := parseACLBinary(tt.data, tt.aclType, tt.control)
			if tt.wantErr {
				if err == nil {
					t.Errorf("parseACLBinary() = %v, wantErr %v", acl, tt.wantErr)
				}
				if acl != nil {
					t.Errorf("parseACLBinary() = %v, wantErr %v", acl, tt.wantErr)
				}
				return
			}

			if err != nil {
				t.Errorf("parseACLBinary() error = %v, wantErr %v", err, tt.wantErr)
				return
			}

			if acl == nil {
				t.Errorf("parseACLBinary() = %v, wantErr %v", acl, tt.wantErr)
				return
			}

			compareACLs(t, "acl", acl, tt.want)

			if aclStr := acl.String(); aclStr != tt.wantStr {
				t.Errorf("parseACLBinary() = %v, want %v", aclStr, tt.wantStr)
			}
		})
	}
}

func TestFromBinary(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		data    []byte
		want    string
		wantErr bool
	}{
		{
			name:    "Invalid data - too short",
			data:    []byte{0x01, 0x00, 0x04},
			want:    "",
			wantErr: true,
		},
		{
			name:    "Invalid data - nil",
			data:    nil,
			want:    "",
			wantErr: true,
		},
		{
			name: "Empty self-relative security descriptor",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x00, 0x80, // Control (SE_SELF_RELATIVE)
				0x00, 0x00, 0x00, 0x00, // Owner
				0x00, 0x00, 0x00, 0x00, // Group
				0x00, 0x00, 0x00, 0x00, // Sacl
				0x00, 0x00, 0x00, 0x00, // Dacl
			},
			want:    "",
			wantErr: false,
		},
		{
			name: "Security descriptor with owner only",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x00, 0x80, // Control (SE_SELF_RELATIVE)
				0x14, 0x00, 0x00, 0x00, // Owner offset
				0x00, 0x00, 0x00, 0x00, // Group
				0x00, 0x00, 0x00, 0x00, // Sacl
				0x00, 0x00, 0x00, 0x00, // Dacl
				// Owner SID (SYSTEM)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority
				0x12, 0x00, 0x00, 0x00, // SubAuthority
			},
			want:    "O:SY",
			wantErr: false,
		},
		{
			name: "Security descriptor with owner and group",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x00, 0x80, // Control (SE_SELF_RELATIVE)
				0x14, 0x00, 0x00, 0x00, // Owner offset (20 bytes from start)
				0x20, 0x00, 0x00, 0x00, // Group offset (32 bytes from start)
				0x00, 0x00, 0x00, 0x00, // Sacl
				0x00, 0x00, 0x00, 0x00, // Dacl
				// Owner SID (SYSTEM)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority
				0x12, 0x00, 0x00, 0x00, // SubAuthority
				// Group SID (Everyone - S-1-1-0)
				0x01,                               // Revision (1)
				0x01,                               // SubAuthorityCount (1)
				0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // IdentifierAuthority (SECURITY_WORLD_SID_AUTHORITY = 1)
				0x00, 0x00, 0x00, 0x00, // SubAuthority[0] = 0 (final component of S-1-1-0)
				// Owner SID (SYSTEM)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00,
				// Group SID (Everyone)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
				0x00, 0x00, 0x00, 0x00,
			},
			want:    "O:SYG:WD",
			wantErr: false,
		},
		{
			name: "Security descriptor with DACL",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x04, 0x80, // Control (SE_SELF_RELATIVE | SE_DACL_PRESENT)
				0x00, 0x00, 0x00, 0x00, // Owner
				0x00, 0x00, 0x00, 0x00, // Group
				0x00, 0x00, 0x00, 0x00, // Sacl
				0x14, 0x00, 0x00, 0x00, // Dacl offset
				// DACL
				0x02,       // Revision
				0x00,       // Sbz1
				0x1C, 0x00, // Size (28 bytes)
				0x01, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// ACE
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x00,       // Flags
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				// SID (SYSTEM)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00,
			},
			want:    "D:(A;;FA;;;SY)",
			wantErr: false,
		},
		{
			name: "Security descriptor with SACL",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x10, 0x80, // Control (SE_SELF_RELATIVE | SE_SACL_PRESENT)
				0x00, 0x00, 0x00, 0x00, // Owner
				0x00, 0x00, 0x00, 0x00, // Group
				0x14, 0x00, 0x00, 0x00, // Sacl offset
				0x00, 0x00, 0x00, 0x00, // Dacl
				// SACL
				0x02,       // Revision
				0x00,       // Sbz1
				0x1C, 0x00, // Size
				0x01, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// ACE
				0x02,       // Type (SYSTEM_AUDIT_ACE_TYPE)
				0x40,       // Flags (SUCCESSFUL_ACCESS_ACE)
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				// SID (SYSTEM)
				0x01, 0x01,
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
				0x12, 0x00, 0x00, 0x00,
			},
			want:    "S:(AU;SA;FA;;;SY)",
			wantErr: false,
		},
		{
			name: "Complete security descriptor with all components",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x14, 0x80, // Control (SE_SELF_RELATIVE | SE_DACL_PRESENT | SE_SACL_PRESENT)
				0x4C, 0x00, 0x00, 0x00, // Owner offset
				0x58, 0x00, 0x00, 0x00, // Group offset
				0x14, 0x00, 0x00, 0x00, // Sacl offset
				0x30, 0x00, 0x00, 0x00, // Dacl offset
				// SACL
				0x02,       // Revision
				0x00,       // Sbz1
				0x1C, 0x00, // Size
				0x01, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// SACL ACE
				0x02,       // Type (SYSTEM_AUDIT_ACE_TYPE)
				0x40,       // Flags (SUCCESSFUL_ACCESS_ACE)
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority (NT)
				0x12, 0x00, 0x00, 0x00, // SubAuthority (18)
				// DACL
				0x02,       // Revision
				0x00,       // Sbz1
				0x1C, 0x00, // Size
				0x01, 0x00, // AceCount
				0x00, 0x00, // Sbz2
				// DACL ACE
				0x00,       // Type (ACCESS_ALLOWED_ACE_TYPE)
				0x00,       // Flags
				0x14, 0x00, // Size
				0xFF, 0x01, 0x1F, 0x00, // Access mask (Full Access)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority (NT)
				0x12, 0x00, 0x00, 0x00, // SubAuthority (18)
				// Owner SID (SYSTEM)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // Authority (NT)
				0x12, 0x00, 0x00, 0x00, // SubAuthority (18)
				// Group SID (Everyone)
				0x01, 0x01, // Revision, SubAuthorityCount
				0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // Authority (WORLD)
				0x00, 0x00, 0x00, 0x00, // SubAuthority (0)
			},
			want:    "O:SYG:WDD:(A;;FA;;;SY)S:(AU;SA;FA;;;SY)",
			wantErr: false,
		},
		{
			name: "Invalid owner offset",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x00, 0x80, // Control
				0xFF, 0xFF, 0xFF, 0xFF, // Owner (invalid offset)
				0x00, 0x00, 0x00, 0x00, // Group
				0x00, 0x00, 0x00, 0x00, // Sacl
				0x00, 0x00, 0x00, 0x00, // Dacl
			},
			want:    "",
			wantErr: true,
		},
		{
			name: "Invalid group offset",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x00, 0x80, // Control
				0x00, 0x00, 0x00, 0x00, // Owner
				0xFF, 0xFF, 0xFF, 0xFF, // Group (invalid offset)
				0x00, 0x00, 0x00, 0x00, // Sacl
				0x00, 0x00, 0x00, 0x00, // Dacl
			},
			want:    "",
			wantErr: true,
		},
		{
			name: "Invalid SACL offset",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x10, 0x80, // Control (SE_SELF_RELATIVE | SE_SACL_PRESENT)
				0x00, 0x00, 0x00, 0x00, // Owner
				0x00, 0x00, 0x00, 0x00, // Group
				0xFF, 0xFF, 0xFF, 0xFF, // Sacl (invalid offset)
				0x00, 0x00, 0x00, 0x00, // Dacl
			},
			want:    "",
			wantErr: true,
		},
		{
			name: "Invalid DACL offset",
			data: []byte{
				0x01,       // Revision
				0x00,       // Sbz1
				0x04, 0x80, // Control (SE_SELF_RELATIVE | SE_DACL_PRESENT)
				0x00, 0x00, 0x00, 0x00, // Owner
				0x00, 0x00, 0x00, 0x00, // Group
				0x00, 0x00, 0x00, 0x00, // Sacl
				0xFF, 0xFF, 0xFF, 0xFF, // Dacl (invalid offset)
			},
			want:    "",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			sd, err := FromBinary(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Errorf("ParseSecurityDescriptorToStruct() error = %v, wantErr %v", err, tt.wantErr)
				}
				if sd != nil {
					t.Errorf("ParseSecurityDescriptorToStruct() = %v, want nil", sd)
				}
				return
			}

			if err != nil {
				t.Errorf("ParseSecurityDescriptorToStruct() error = %v, wantErr %v", err, tt.wantErr)
				return
			}

			if sd == nil {
				t.Errorf("ParseSecurityDescriptorToStruct() = nil, want not nil")
				return
			}

			sdStr := sd.String()
			if sdStr != tt.want {
				t.Errorf("ParseSecurityDescriptor() = %v, want %v", sdStr, tt.want)
			}
		})
	}
}
