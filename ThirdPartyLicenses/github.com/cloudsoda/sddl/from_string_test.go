package sddl

import (
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestParseACEString(t *testing.T) {
	// Helper function to create a SID for testing
	createTestSID := func(revision byte, authority uint64, subAuth ...uint32) *sid {
		return &sid{
			revision:            revision,
			identifierAuthority: authority,
			subAuthority:        subAuth,
		}
	}

	tests := []struct {
		name    string
		aceStr  string
		want    *ace
		wantErr bool
	}{
		{
			name:   "Basic allow ACE",
			aceStr: "(A;;FA;;;SY)",
			want: &ace{
				header: &aceHeader{
					aceType:  accessAllowedACEType,
					aceFlags: 0,
					aceSize:  20, // 4 (header) + 4 (mask) + 12 (SID with 1 sub-authority)
				},
				accessMask: 0x1F01FF,                // FA - Full Access
				sid:        createTestSID(1, 5, 18), // SY - Local System
			},
			wantErr: false,
		},
		{
			name:   "Deny ACE with inheritance flags",
			aceStr: "(D;OICI;FR;;;BA)",
			want: &ace{
				header: &aceHeader{
					aceType:  accessDeniedACEType,
					aceFlags: objectInheritACE | containerInheritACE,
					aceSize:  24, // 4 (header) + 4 (mask) + 16 (SID with 2 sub-authorities)
				},
				accessMask: 0x120089,                     // FR - File Read
				sid:        createTestSID(1, 5, 32, 544), // BA - Builtin Administrators
			},
			wantErr: false,
		},
		{
			name:   "Audit ACE with success audit",
			aceStr: "(AU;SA;FA;;;WD)",
			want: &ace{
				header: &aceHeader{
					aceType:  systemAuditACEType,
					aceFlags: successfulAccessACE,
					aceSize:  20, // 4 (header) + 4 (mask) + 12 (SID with 1 sub-authority)
				},
				accessMask: 0x1F01FF,               // FA
				sid:        createTestSID(1, 1, 0), // WD - Everyone
			},
			wantErr: false,
		},
		{
			name:   "Audit ACE with both success and failure",
			aceStr: "(AU;SAFA;FA;;;SY)",
			want: &ace{
				header: &aceHeader{
					aceType:  systemAuditACEType,
					aceFlags: successfulAccessACE | failedAccessACE,
					aceSize:  20,
				},
				accessMask: 0x1F01FF,
				sid:        createTestSID(1, 5, 18),
			},
			wantErr: false,
		},
		{
			name:   "Complex inheritance flags",
			aceStr: "(A;OICIIONP;FA;;;AU)",
			want: &ace{
				header: &aceHeader{
					aceType:  accessAllowedACEType,
					aceFlags: objectInheritACE | containerInheritACE | inheritOnlyACE | noPropagateInheritACE,
					aceSize:  20,
				},
				accessMask: 0x1F01FF,
				sid:        createTestSID(1, 5, 11), // AU - Authenticated Users
			},
			wantErr: false,
		},
		{
			name:   "Directory operations access mask",
			aceStr: "(A;;DCLCRPCR;;;SY)",
			want: &ace{
				header: &aceHeader{
					aceType:  accessAllowedACEType,
					aceFlags: 0,
					aceSize:  20, // 4 (header) + 4 (access mask) + 12 (SID with 1 sub-authority)
				},
				accessMask: 0x000116, // Directory Create/List/Read/Pass through/Child rename/Child delete
				sid:        createTestSID(1, 5, 18),
			},
			wantErr: false,
		},
		{
			name:   "Custom access mask",
			aceStr: "(A;;0x1234ABCD;;;SY)",
			want: &ace{
				header: &aceHeader{
					aceType:  accessAllowedACEType,
					aceFlags: 0,
					aceSize:  20, // 4 (header) + 4 (mask) + 12 (SID with 1 sub-authority)
				},
				accessMask: 0x1234ABCD,
				sid:        createTestSID(1, 5, 18),
			},
			wantErr: false,
		},
		{
			name:   "Custom ACE type",
			aceStr: "(0x15;;FA;;;SY)", // SYSTEM_ACCESS_FILTER_ACE_TYPE
			want: &ace{
				header: &aceHeader{
					aceType:  0x15,
					aceFlags: 0,
					aceSize:  20, // 4 (header) + 4 (access mask) + 12 (SID with 1 sub-authority)
				},
				accessMask: 0x1F01FF,
				sid:        createTestSID(1, 5, 18),
			},
			wantErr: false,
		},
		// Error cases
		{
			name:    "Invalid format - missing parentheses",
			aceStr:  "A;;FA;;;SY",
			wantErr: true,
		},
		{
			name:    "Invalid format - wrong number of components",
			aceStr:  "(A;FA;;;SY)",
			wantErr: true,
		},
		{
			name:    "Invalid ACE type",
			aceStr:  "(X;;FA;;;SY)",
			wantErr: true,
		},
		{
			name:    "Invalid hex ACE type",
			aceStr:  "(0xZZ;;FA;;;SY)",
			wantErr: true,
		},
		{
			name:    "Invalid flags format",
			aceStr:  "(A;OIC;FA;;;SY)", // Incomplete flag pair
			wantErr: true,
		},
		{
			name:    "Unknown flag",
			aceStr:  "(A;XXXX;FA;;;SY)",
			wantErr: true,
		},
		{
			name:    "Audit flags on non-audit ACE",
			aceStr:  "(A;SAFA;FA;;;SY)",
			wantErr: true,
		},
		{
			name:    "Audit ACE without audit flags",
			aceStr:  "(AU;OICI;FA;;;SY)",
			wantErr: true,
		},
		{
			name:    "Invalid access mask",
			aceStr:  "(A;;XX;;;SY)",
			wantErr: true,
		},
		{
			name:    "Invalid hex access mask",
			aceStr:  "(A;;0xZZZZ;;;SY)",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotR, err := parseACEString(tt.aceStr)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseACEString() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if tt.wantErr {
				return
			}

			if gotR == nil {
				t.Errorf("ParseACEString() returned nil, want non-nil")
				return
			}

			got, err := gotR.toACE(tt.want.sids())
			if err != nil {
				t.Errorf("toACE() error = %v", err)
				return
			}

			// Compare Header fields
			if got.header.aceType != tt.want.header.aceType {
				t.Errorf("ACE Type = %v, want %v", got.header.aceType, tt.want.header.aceType)
			}
			if got.header.aceFlags != tt.want.header.aceFlags {
				t.Errorf("ACE Flags = %v, want %v", got.header.aceFlags, tt.want.header.aceFlags)
			}
			if got.header.aceSize != tt.want.header.aceSize {
				t.Errorf("ACE Size = %v, want %v", got.header.aceSize, tt.want.header.aceSize)
			}

			// Compare AccessMask
			if got.accessMask != tt.want.accessMask {
				t.Errorf("AccessMask = %v, want %v", got.accessMask, tt.want.accessMask)
			}

			// Compare SID fields
			if got.sid.revision != tt.want.sid.revision {
				t.Errorf("SID Revision = %v, want %v", got.sid.revision, tt.want.sid.revision)
			}
			if got.sid.identifierAuthority != tt.want.sid.identifierAuthority {
				t.Errorf("SID Authority = %v, want %v", got.sid.identifierAuthority, tt.want.sid.identifierAuthority)
			}
			if !reflect.DeepEqual(got.sid.subAuthority, tt.want.sid.subAuthority) {
				t.Errorf("SID SubAuthority = %v, want %v", got.sid.subAuthority, tt.want.sid.subAuthority)
			}
		})
	}
}

func TestParseACLString(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		aclType   string
		input     string
		want      *acl
		wantErr   bool
		errString string
	}{
		{
			name:      "Invalid ACL type",
			aclType:   "X",
			input:     "(A;;FA;;;SY)",
			wantErr:   true,
			errString: "invalid ACL type: must be either 'D' or 'S'",
		},
		{
			name:    "Empty DACL",
			aclType: "D",
			input:   "",
			want: &acl{
				aclRevision: 2,
				aclSize:     8,
				aclType:     "D",
				control:     seDACLPresent,
			},
		},
		{
			name:    "Empty SACL",
			aclType: "S",
			input:   "",
			want: &acl{
				aclRevision: 2,
				aclSize:     8,
				aclType:     "S",
				control:     seSACLPresent,
			},
		},
		{
			name:    "Basic DACL with single ACE",
			aclType: "D",
			input:   "(A;;FA;;;SY)",
			want: &acl{
				aclRevision: 2,
				aclSize:     28, // 8 (header) + 20 (ACE size)
				aceCount:    1,
				aclType:     "D",
				control:     seDACLPresent,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  accessAllowedACEType,
							aceFlags: 0,
							aceSize:  20,
						},
						accessMask: 0x1F01FF, // FA - Full Access
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{18}, // SYSTEM
						},
					},
				},
			},
		},
		{
			name:    "DACL with multiple ACEs",
			aclType: "D",
			input:   "(A;;FA;;;SY)(D;;FR;;;WD)",
			want: &acl{
				aclRevision: 2,
				aclSize:     48, // 8 (header) + 20 (first ACE) + 20 (second ACE)
				aceCount:    2,
				aclType:     "D",
				control:     seDACLPresent,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  accessAllowedACEType,
							aceFlags: 0,
							aceSize:  20,
						},
						accessMask: 0x1F01FF, // FA
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{18}, // SYSTEM
						},
					},
					{
						header: &aceHeader{
							aceType:  accessDeniedACEType,
							aceFlags: 0,
							aceSize:  20,
						},
						accessMask: 0x120089, // FR
						sid: &sid{
							revision:            1,
							identifierAuthority: 1,
							subAuthority:        []uint32{0}, // Everyone
						},
					},
				},
			},
		},
		{
			name:    "SACL with audit ACE",
			aclType: "S",
			input:   "(AU;SA;FA;;;SY)",
			want: &acl{
				aclRevision: 2,
				aclSize:     28,
				aceCount:    1,
				aclType:     "S",
				control:     seSACLPresent,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  systemAuditACEType,
							aceFlags: successfulAccessACE,
							aceSize:  20,
						},
						accessMask: 0x1F01FF,
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{18},
						},
					},
				},
			},
		},
		{
			name:    "DACL with protected flag",
			aclType: "D",
			input:   "P(A;;FA;;;SY)",
			want: &acl{
				aclRevision: 2,
				aclSize:     28,
				aceCount:    1,
				aclType:     "D",
				control:     seDACLPresent | seDACLProtected,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  accessAllowedACEType,
							aceFlags: 0,
							aceSize:  20,
						},
						accessMask: 0x1F01FF,
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{18},
						},
					},
				},
			},
		},
		{
			name:    "DACL with auto-inherited flag",
			aclType: "D",
			input:   "AI(A;;FA;;;SY)",
			want: &acl{
				aclRevision: 2,
				aclSize:     28,
				aceCount:    1,
				aclType:     "D",
				control:     seDACLPresent | seDACLAutoInherited,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  accessAllowedACEType,
							aceFlags: 0,
							aceSize:  20,
						},
						accessMask: 0x1F01FF,
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{18},
						},
					},
				},
			},
		},
		{
			name:    "SACL with multiple flags",
			aclType: "S",
			input:   "PAI(AU;SA;FA;;;SY)",
			want: &acl{
				aclRevision: 2,
				aclSize:     28,
				aceCount:    1,
				aclType:     "S",
				control:     seSACLPresent | seSACLProtected | seSACLAutoInherited,
				aces: []ace{
					{
						header: &aceHeader{
							aceType:  systemAuditACEType,
							aceFlags: successfulAccessACE,
							aceSize:  20,
						},
						accessMask: 0x1F01FF,
						sid: &sid{
							revision:            1,
							identifierAuthority: 5,
							subAuthority:        []uint32{18},
						},
					},
				},
			},
		},
		{
			name:      "Invalid ACE format",
			aclType:   "D",
			input:     "A;;FA;;;SY)", // Missing opening parenthesis
			wantErr:   true,
			errString: "invalid ACL format: missing opening parenthesis",
		},
		{
			name:      "Missing closing parenthesis",
			aclType:   "D",
			input:     "(A;;FA;;;SY",
			wantErr:   true,
			errString: "invalid ACE format: missing closing parenthesis",
		},
		{
			name:    "Empty DACL with flags",
			aclType: "D",
			input:   "PAI",
			want: &acl{
				aclRevision: 2,
				aclSize:     8,
				aclType:     "D",
				control:     seDACLPresent | seDACLProtected | seDACLAutoInherited,
			},
		},
	}

	for _, tt := range tests {
		tt := tt // Capture range variable for parallel testing
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			gotR, err := parseACLString(tt.aclType, tt.input)

			// Check error cases
			if tt.wantErr {
				if err == nil {
					t.Errorf("parseACLFromString() error= nil, wantErr = true")
					return /*  */
				}
				if tt.errString != "" && err.Error() != tt.errString {
					t.Errorf("parseACLFromString() error = %v, wantErr = %v", err, tt.errString)
				}
				return
			}

			// Check non-error cases
			if err != nil {
				t.Errorf("parseACLFromString() unexpected error = %v", err)
				return
			}

			if gotR == nil {
				t.Fatal("parseACLFromString() = nil, want non-nil")
			}

			got, err := gotR.toACL(tt.want.sids())
			if err != nil {
				t.Errorf("toACL() unexpected error = %v", err)
				return
			}

			// Compare ACL fields
			if got.aclRevision != tt.want.aclRevision {
				t.Errorf("AclRevision = %v, want %v", got.aclRevision, tt.want.aclRevision)
			}
			if got.aclSize != tt.want.aclSize {
				t.Errorf("AclSize = %v, want %v", got.aclSize, tt.want.aclSize)
			}
			if got.aceCount != tt.want.aceCount {
				t.Errorf("AceCount = %v, want %v", got.aceCount, tt.want.aceCount)
			}
			if got.aclType != tt.want.aclType {
				t.Errorf("AclType = %v, want %v", got.aclType, tt.want.aclType)
			}
			if got.control != tt.want.control {
				t.Errorf("Control = %v, want %v", got.control, tt.want.control)
			}

			// Compare ACEs
			if len(got.aces) != len(tt.want.aces) {
				t.Errorf("len(ACEs) = %v, want %v", len(got.aces), len(tt.want.aces))
				return
			}

			for i := range got.aces {
				// Compare ACE Header
				if got.aces[i].header.aceType != tt.want.aces[i].header.aceType {
					t.Errorf("ACE[%d].Header.AceType = %v, want %v",
						i, got.aces[i].header.aceType, tt.want.aces[i].header.aceType)
				}
				if got.aces[i].header.aceFlags != tt.want.aces[i].header.aceFlags {
					t.Errorf("ACE[%d].Header.AceFlags = %v, want %v",
						i, got.aces[i].header.aceFlags, tt.want.aces[i].header.aceFlags)
				}
				if got.aces[i].header.aceSize != tt.want.aces[i].header.aceSize {
					t.Errorf("ACE[%d].Header.AceSize = %v, want %v",
						i, got.aces[i].header.aceSize, tt.want.aces[i].header.aceSize)
				}

				// Compare ACE AccessMask
				if got.aces[i].accessMask != tt.want.aces[i].accessMask {
					t.Errorf("ACE[%d].AccessMask = %v, want %v",
						i, got.aces[i].accessMask, tt.want.aces[i].accessMask)
				}

				// Compare ACE SID
				if !reflect.DeepEqual(got.aces[i].sid, tt.want.aces[i].sid) {
					t.Errorf("ACE[%d].SID = %v, want %v",
						i, got.aces[i].sid, tt.want.aces[i].sid)
				}
			}
		})
	}
}

func TestFromString(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		input   string
		want    *SecurityDescriptor
		wantErr bool
	}{
		{
			name:  "Empty string",
			input: "",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seDACLDefaulted | seSACLDefaulted,
			},
			wantErr: false,
		},

		{
			name:  "Owner only",
			input: "O:SY",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seGroupDefaulted | seDACLDefaulted | seSACLDefaulted,
				ownerSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{18},
				},
			},
			wantErr: false,
		},

		{
			name:  "Group only",
			input: "G:BA",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seOwnerDefaulted | seDACLDefaulted | seSACLDefaulted,
				groupSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{32, 544},
				},
			},
			wantErr: false,
		},

		{
			name:  "Owner and Group only",
			input: "O:SYG:BA",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seDACLDefaulted | seSACLDefaulted,
				ownerSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{18},
				},
				groupSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{32, 544},
				},
			},
			wantErr: false,
		},

		{
			name:  "Only Empty DACL",
			input: "D:",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seSACLDefaulted | seDACLPresent,
				dacl: &acl{
					aclRevision: 2,
					aclSize:     8,
					aclType:     "D",
					control:     seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seSACLDefaulted | seDACLPresent, // This field is a copy of SD.Control
				},
			},
			wantErr: false,
		},

		{
			name:  "Only Empty SACL",
			input: "S:",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seDACLDefaulted | seSACLPresent,
				sacl: &acl{
					aclRevision: 2,
					aclSize:     8,
					aclType:     "S",
					control:     seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seDACLDefaulted | seSACLPresent, // This field is a copy of SD.Control
				},
			},
			wantErr: false,
		},

		{
			name:  "Protected DACL",
			input: "D:P(A;;FA;;;SY)",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seSACLDefaulted | seDACLPresent | seDACLProtected,
				dacl: &acl{
					aclRevision: 2,
					aclSize:     28,
					aceCount:    1,
					aclType:     "D",
					control:     seSelfRelative | seOwnerDefaulted | seGroupDefaulted | seSACLDefaulted | seDACLPresent | seDACLProtected, // This field is a copy of SD.Control
					aces: []ace{
						{
							header: &aceHeader{
								aceType:  accessAllowedACEType,
								aceFlags: 0,
								aceSize:  20,
							},
							accessMask: 0x1F01FF,
							sid: &sid{
								revision:            1,
								identifierAuthority: 5,
								subAuthority:        []uint32{18},
							},
						},
					},
				},
			},
			wantErr: false,
		},

		{
			name:  "Complete security descriptor",
			input: "O:SYG:BAD:PAI(A;;FA;;;SY)(D;;FR;;;WD)S:AI(AU;SA;FA;;;BA)",
			want: &SecurityDescriptor{
				revision: 1,
				control:  seDACLAutoInherited | seDACLPresent | seDACLProtected | seSACLAutoInherited | seSACLPresent | seSelfRelative,
				ownerSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{18},
				},
				groupSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{32, 544},
				},
				dacl: &acl{
					aclRevision: 2,
					aclSize:     48, // 4 bytes for AceCount and Sbz1, 40 bytes for the two ACEs, 4 bytes for Sbz2
					aceCount:    2,
					aclType:     "D",
					control: seDACLAutoInherited | seDACLPresent | seDACLProtected |
						seSACLAutoInherited | seSACLPresent | seSelfRelative, // This field is a copy of SD.Control
					aces: []ace{
						{
							header: &aceHeader{
								aceType:  accessAllowedACEType,
								aceFlags: 0,
								aceSize:  20, // 4 bytes for ACE header + 4 bytes for mask + 12 bytes for SID
							},
							accessMask: 0x1F01FF,
							sid: &sid{
								revision:            1,
								identifierAuthority: 5,
								subAuthority:        []uint32{18},
							},
						},
						{
							header: &aceHeader{
								aceType:  accessDeniedACEType,
								aceFlags: 0,
								aceSize:  20, // 4 bytes for ACE header + 4 bytes for mask + 12 bytes for SID
							},
							accessMask: 0x120089,
							sid: &sid{
								revision:            1,
								identifierAuthority: 1,
								subAuthority:        []uint32{0},
							},
						},
					},
				},
				sacl: &acl{
					aclRevision: 2,
					aclSize:     32, // 4 bytes for AceCount and Sbz1, 24 bytes for the single ACE, 4 bytes for Sbz2
					aceCount:    1,
					aclType:     "S",
					control: seDACLAutoInherited | seDACLPresent | seDACLProtected |
						seSACLAutoInherited | seSACLPresent | seSelfRelative, // This field is a copy of SD.Control
					aces: []ace{
						{
							header: &aceHeader{
								aceType:  systemAuditACEType,
								aceFlags: successfulAccessACE,
								aceSize:  24, // 4 bytes for ACE header, 4 bytes for access mask, 8 bytes for SID header, 4 bytes for 1 sub-authority
							},
							accessMask: 0x1F01FF,
							sid: &sid{
								revision:            1,
								identifierAuthority: 5,
								subAuthority:        []uint32{32, 544},
							},
						},
					},
				},
			},
			wantErr: false,
		},

		{
			name:    "Invalid format - no separator",
			input:   "O-SY",
			wantErr: true,
		},

		{
			name:    "Invalid SID format",
			input:   "O:INVALID",
			wantErr: true,
		},

		{
			name:    "Invalid DACL format",
			input:   "D:X",
			wantErr: true,
		},

		{
			name:    "Invalid ACE format",
			input:   "D:(A;FR;;;SY", // Missing closing parenthesis
			wantErr: true,
		},

		{
			name:    "Non-standard order of components",
			input:   "D:(A;;FA;;;SY)O:SY",
			wantErr: false,
			want: &SecurityDescriptor{
				revision: 1,
				control:  seSelfRelative | seGroupDefaulted | seSACLDefaulted | seDACLPresent,
				dacl: &acl{
					aclRevision: 2,
					aclSize:     28, // 4 bytes for AceCount and Sbz1, 20 bytes for the single ACE, 4 bytes for Sbz2
					aceCount:    1,
					aclType:     "D",
					control:     seSelfRelative | seGroupDefaulted | seSACLDefaulted | seDACLPresent, // This field is a copy of SD.Control
					aces: []ace{
						{
							header: &aceHeader{
								aceType:  accessAllowedACEType,
								aceFlags: 0,
								aceSize:  20, // 4 bytes for ACE header + 4 bytes for mask + 12 bytes for SID
							},
							accessMask: 0x1F01FF,
							sid: &sid{
								revision:            1,
								identifierAuthority: 5,
								subAuthority:        []uint32{18},
							},
						},
					},
				},
				ownerSID: &sid{
					revision:            1,
					identifierAuthority: 5,
					subAuthority:        []uint32{18},
				},
			},
		},

		{
			name:  "All control flags",
			input: "D:PAIARRNOIOS:PAIARRNOIO",
			want: &SecurityDescriptor{
				revision: 1,
				control: seSelfRelative | seOwnerDefaulted | seGroupDefaulted |
					seDACLPresent | seSACLPresent |
					seDACLProtected | seDACLAutoInherited | seDACLAutoInheritRe |
					seSACLProtected | seSACLAutoInherited | seSACLAutoInheritRe,
				dacl: &acl{
					aclRevision: 2,
					aclSize:     8,
					aclType:     "D",
					control: seSelfRelative | seOwnerDefaulted | seGroupDefaulted |
						seDACLPresent | seSACLPresent |
						seDACLProtected | seDACLAutoInherited | seDACLAutoInheritRe |
						seSACLProtected | seSACLAutoInherited | seSACLAutoInheritRe, // This field is a copy of SD.Control
				},
				sacl: &acl{
					aclRevision: 2,
					aclSize:     8,
					aclType:     "S",
					control: seSelfRelative | seOwnerDefaulted | seGroupDefaulted |
						seDACLPresent | seSACLPresent |
						seDACLProtected | seDACLAutoInherited | seDACLAutoInheritRe |
						seSACLProtected | seSACLAutoInherited | seSACLAutoInheritRe, // This field is a copy of SD.Control
				},
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		tt := tt // Capture range variable for parallel testing
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := FromString(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Errorf("ParseSecurityDescriptorString() error = nil, wantErr = true")
				}
				return
			}

			if err != nil {
				t.Errorf("ParseSecurityDescriptorString() unexpected error = %v", err)
				return
			}

			// Compare SecurityDescriptor fields
			compareSecurityDescriptors(t, got, tt.want)
		})
	}
}

func TestParseSIDString(t *testing.T) {
	// Test high authority values close to boundary conditions
	maxAuthority := uint64(1<<48 - 1)

	tests := []struct {
		name    string
		input   string
		want    *sid
		wantErr error
	}{
		{
			name:  "Well-known SID short form (SYSTEM)",
			input: "SY",
			want: &sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{18},
			},
		},
		{
			name:  "Well-known SID full form (SYSTEM)",
			input: "S-1-5-18",
			want: &sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{18},
			},
		},
		{
			name:  "Complex SID",
			input: "S-1-5-21-3623811015-3361044348-30300820-1013",
			want: &sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{21, 3623811015, 3361044348, 30300820, 1013},
			},
		},
		{
			name:  "Minimum valid SID",
			input: "S-1-0-0",
			want: &sid{
				revision:            1,
				identifierAuthority: 0,
				subAuthority:        []uint32{0},
			},
		},
		{
			name:  "Maximum sub-authorities",
			input: "S-1-5-21-1-2-3-4-5-6-7-8-9-10-11-12-13-14",
			want: &sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{21, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14},
			},
		},
		{
			name:    "Invalid format - no S- prefix",
			input:   "1-5-18",
			wantErr: ErrInvalidSIDFormat,
		},
		{
			name:    "Invalid format - empty string",
			input:   "",
			wantErr: ErrInvalidSIDFormat,
		},
		{
			name:    "Invalid format - missing components",
			input:   "S-1",
			wantErr: ErrInvalidSIDFormat,
		},
		{
			name:    "Invalid revision",
			input:   "S-2-5-18",
			wantErr: ErrInvalidRevision,
		},
		{
			name:    "Invalid revision - not a number",
			input:   "S-X-5-18",
			wantErr: ErrInvalidRevision,
		},
		{
			name:    "Invalid authority - not a number",
			input:   "S-1-X-18",
			wantErr: ErrInvalidAuthority,
		},
		{
			name:    "Invalid sub-authority - not a number",
			input:   "S-1-5-X",
			wantErr: ErrInvalidSubAuthority,
		},
		{
			name:    "Too many sub-authorities",
			input:   "S-1-5-21-1-2-3-4-5-6-7-8-9-10-11-12-13-14-15-16",
			wantErr: ErrTooManySubAuthorities,
		},
		{
			name:  "High authority value in hex",
			input: "S-1-0xFFFFFFFF0000-1-2",
			want: &sid{
				revision:            1,
				identifierAuthority: 0xFFFFFFFF0000,
				subAuthority:        []uint32{1, 2},
			},
		},
		{
			name:  "Authority value just below 2^32 in decimal",
			input: "S-1-4294967295-1-2",
			want: &sid{
				revision:            1,
				identifierAuthority: 4294967295,
				subAuthority:        []uint32{1, 2},
			},
		},
		{
			name:  "Authority value maximum (2^48-1) in hex",
			input: fmt.Sprintf("S-1-0x%X-1-2", maxAuthority),
			want: &sid{
				revision:            1,
				identifierAuthority: maxAuthority,
				subAuthority:        []uint32{1, 2},
			},
		},
		{
			name:    "Authority value too large in hex",
			input:   "S-1-0x1000000000000-1-2", // 2^48
			wantErr: ErrInvalidAuthority,
		},
		{
			name:    "Invalid hex authority format - bad characters",
			input:   "S-1-0xGHIJKL-1-2",
			wantErr: ErrInvalidAuthority,
		},
		{
			name:    "Invalid hex authority format - missing digits",
			input:   "S-1-0x-1-2",
			wantErr: ErrInvalidAuthority,
		},
	}

	for _, tt := range tests {
		tt := tt // capture range variable for parallel execution
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel() // Enable parallel execution

			gotR, err := parseSIDString(tt.input)

			if tt.wantErr != nil {
				if gotR != nil {
					t.Error("parseSIDString() returned non-nil SID when error was expected")
				}
				if err == nil {
					t.Errorf("parseSIDString() error = nil, wantErr %v", tt.wantErr)
					return
				}
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("parseSIDString() error = %v, wantErr %v", err, tt.wantErr)
				}
				return
			}

			if err != nil {
				t.Errorf("parseSIDString() unexpected error = %v", err)
				return
			}

			if gotR == nil {
				t.Error("parseSIDString() returned nil SID when success was expected")
				return
			}

			got, err := gotR.toSID(tt.want.sids())
			if err != nil {
				t.Errorf("toSID() unexpected error = %v", err)
				return
			}

			if got.revision != tt.want.revision {
				t.Errorf("Revision = %v, want %v", got.revision, tt.want.revision)
			}
			if got.identifierAuthority != tt.want.identifierAuthority {
				t.Errorf("IdentifierAuthority = %v, want %v",
					got.identifierAuthority, tt.want.identifierAuthority)
			}
			if len(got.subAuthority) != len(tt.want.subAuthority) {
				t.Errorf("SubAuthority length = %v, want %v",
					len(got.subAuthority), len(tt.want.subAuthority))
			} else {
				for i := range got.subAuthority {
					if got.subAuthority[i] != tt.want.subAuthority[i] {
						t.Errorf("SubAuthority[%d] = %v, want %v",
							i, got.subAuthority[i], tt.want.subAuthority[i])
					}
				}
			}
		})
	}
}

func TestComplete(t *testing.T) {
	tests := []struct {
		name    string
		r       rid
		s       sid
		want    *sid
		wantErr error
	}{
		{
			name: "Valid completion",
			r:    rid(300), // on purpose is not a well-known RID so we can verify in test report
			s: sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{21, 123, 456, 789, 2983},
			},
			want: &sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{21, 123, 456, 789, 300},
			},
			wantErr: nil,
		},
		{
			name: "Empty sub-authority",
			r:    rid(300),
			s: sid{
				revision:            1,
				identifierAuthority: 5,
				subAuthority:        []uint32{},
			},
			want:    nil,
			wantErr: ErrMissingSubAuthorities,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := tt.r.complete(tt.s)
			if !errors.Is(err, tt.wantErr) {
				t.Errorf("complete() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if tt.wantErr == nil {
				if got == nil {
					t.Fatal("complete() returned nil, want valid sid")
				}
				if !reflect.DeepEqual(got, tt.want) {
					t.Errorf("complete() = %v, want %v", got, tt.want)
				}
			}
		})
	}
}

// Helper function to compare ACL fields
func compareACLs(t *testing.T, prefix string, got, want *acl) {
	t.Helper()

	if got.aclRevision != want.aclRevision {
		t.Errorf("%s.AclRevision = %v, want %v", prefix, got.aclRevision, want.aclRevision)
		t.FailNow()
		return
	}

	if got.aclSize != want.aclSize {
		t.Errorf("%s.AclSize = %v, want %v", prefix, got.aclSize, want.aclSize)
		t.FailNow()
		return
	}

	if got.aceCount != want.aceCount {
		t.Errorf("%s.AceCount = %v, want %v", prefix, got.aceCount, want.aceCount)
		t.FailNow()
		return
	}

	if got.aclType != want.aclType {
		t.Errorf("%s.AclType = %v, want %v", prefix, got.aclType, want.aclType)
		t.FailNow()
		return
	}

	if got.control != want.control {
		t.Errorf("%s.Control = %v, want %v", prefix, got.control, want.control)
		t.FailNow()
		return
	}

	// Compare ACEs
	if len(got.aces) != len(want.aces) {
		t.Errorf("%s.ACEs length = %v, want %v", prefix, len(got.aces), len(want.aces))
		t.FailNow()
		return
	}

	for i := range got.aces {
		// Compare ACE Header
		if got.aces[i].header.aceType != want.aces[i].header.aceType {
			t.Errorf("%s.ACE[%d].Header.AceType = %v, want %v",
				prefix, i, got.aces[i].header.aceType, want.aces[i].header.aceType)
		}
		if got.aces[i].header.aceFlags != want.aces[i].header.aceFlags {
			t.Errorf("%s.ACE[%d].Header.AceFlags = %v, want %v",
				prefix, i, got.aces[i].header.aceFlags, want.aces[i].header.aceFlags)
		}
		if got.aces[i].header.aceSize != want.aces[i].header.aceSize {
			t.Errorf("%s.ACE[%d].Header.AceSize = %v, want %v",
				prefix, i, got.aces[i].header.aceSize, want.aces[i].header.aceSize)
		}

		// Compare ACE AccessMask
		if got.aces[i].accessMask != want.aces[i].accessMask {
			t.Errorf("%s.ACE[%d].AccessMask = %v, want %v",
				prefix, i, got.aces[i].accessMask, want.aces[i].accessMask)
		}

		// Compare ACE SID
		if !reflect.DeepEqual(got.aces[i].sid, want.aces[i].sid) {
			t.Errorf("%s.ACE[%d].SID = %v, want %v",
				prefix, i, got.aces[i].sid, want.aces[i].sid)
		}
	}
}

// Helper function to compare ACE fields
func compareACEs(t *testing.T, prefix string, got, want *ace) {
	t.Helper()

	// Compare ACE Header
	if got.header.aceType != want.header.aceType {
		t.Errorf("%s.Header.AceType = %v, want %v", prefix, got.header.aceType, want.header.aceType)
		t.FailNow()
		return
	}

	if got.header.aceFlags != want.header.aceFlags {
		t.Errorf("%s.Header.AceFlags = %v, want %v", prefix, got.header.aceFlags, want.header.aceFlags)
		t.FailNow()
		return
	}

	if got.header.aceSize != want.header.aceSize {
		t.Errorf("%s.Header.AceSize = %v, want %v", prefix, got.header.aceSize, want.header.aceSize)
		t.FailNow()
		return
	}

	// Compare ACE AccessMask
	if got.accessMask != want.accessMask {
		t.Errorf("%s.AccessMask = %v, want %v", prefix, got.accessMask, want.accessMask)
		t.FailNow()
		return
	}

	// Compare ACE SID
	if (got.sid == nil) != (want.sid == nil) {
		t.Errorf("%s.SID presence mismatch: got %v, want %v", prefix, got.sid != nil, want.sid != nil)
		t.FailNow()
		return
	} else if got.sid != nil {
		compareSIDs(t, prefix+".SID", got.sid, want.sid)
	}
}

// Helper function to compare control flags with detailed difference reporting
func compareControlFlags(t *testing.T, got, want uint16) {
	t.Helper()

	// If flags match exactly, no need to do detailed comparison
	if got == want {
		return
	}

	// Map of control flags to their string descriptions
	controlFlagNames := map[uint16]string{
		seOwnerDefaulted:    "SE_OWNER_DEFAULTED",
		seGroupDefaulted:    "SE_GROUP_DEFAULTED",
		seDACLPresent:       "SE_DACL_PRESENT",
		seDACLDefaulted:     "SE_DACL_DEFAULTED",
		seSACLPresent:       "SE_SACL_PRESENT",
		seSACLDefaulted:     "SE_SACL_DEFAULTED",
		seDACLAutoInheritRe: "SE_DACL_AUTO_INHERIT_RE",
		seSACLAutoInheritRe: "SE_SACL_AUTO_INHERIT_RE",
		seDACLAutoInherited: "SE_DACL_AUTO_INHERITED",
		seSACLAutoInherited: "SE_SACL_AUTO_INHERITED",
		seDACLProtected:     "SE_DACL_PROTECTED",
		seSACLProtected:     "SE_SACL_PROTECTED",
		seSelfRelative:      "SE_SELF_RELATIVE",
	}

	// Build arrays of flag differences
	var (
		missingFlags []string // Flags that are in 'want' but not in 'got'
		extraFlags   []string // Flags that are in 'got' but not in 'want'
	)

	// Check each known flag
	for flag, flagName := range controlFlagNames {
		hasFlag := got&flag != 0
		wantFlag := want&flag != 0

		if wantFlag && !hasFlag {
			missingFlags = append(missingFlags, flagName)
		} else if hasFlag && !wantFlag {
			extraFlags = append(extraFlags, flagName)
		}
	}

	// Detect any unknown flags
	knownFlags := uint16(0)
	for flag := range controlFlagNames {
		knownFlags |= flag
	}

	unknownGot := got &^ knownFlags
	unknownWant := want &^ knownFlags

	if unknownGot != 0 {
		extraFlags = append(extraFlags, fmt.Sprintf("unknown_flags(0x%04x)", unknownGot))
	}
	if unknownWant != 0 {
		missingFlags = append(missingFlags, fmt.Sprintf("unknown_flags(0x%04x)", unknownWant))
	}

	// Sort the arrays for consistent output
	sort.Strings(missingFlags)
	sort.Strings(extraFlags)

	// Build the error message
	var msg strings.Builder
	msg.WriteString(fmt.Sprintf("Control flags mismatch (got=0x%04x, want=0x%04x):\n", got, want))

	if len(missingFlags) > 0 {
		msg.WriteString("  Missing flags:\n")
		for _, flag := range missingFlags {
			msg.WriteString(fmt.Sprintf("    - %s\n", flag))
		}
	}

	if len(extraFlags) > 0 {
		msg.WriteString("  Extra flags:\n")
		for _, flag := range extraFlags {
			msg.WriteString(fmt.Sprintf("    + %s\n", flag))
		}
	}

	t.Error(msg.String())
	t.FailNow()
}

// Helper function to compare SecurityDescriptor fields
func compareSecurityDescriptors(t *testing.T, got, want *SecurityDescriptor) {
	t.Helper()

	if got.revision != want.revision {
		t.Errorf("Revision = %v, want %v", got.revision, want.revision)
		t.FailNow()
		return
	}

	compareControlFlags(t, got.control, want.control)

	// Compare Owner SID
	if (got.ownerSID == nil) != (want.ownerSID == nil) {
		t.Errorf("OwnerSID presence mismatch: got %v, want %v", got.ownerSID != nil, want.ownerSID != nil)
		t.FailNow()
		return
	} else if got.ownerSID != nil {
		compareSIDs(t, "OwnerSID", got.ownerSID, want.ownerSID)
	}

	// Compare Group SID
	if (got.groupSID == nil) != (want.groupSID == nil) {
		t.Errorf("GroupSID presence mismatch: got %v, want %v", got.groupSID != nil, want.groupSID != nil)
		t.FailNow()
		return
	} else if got.groupSID != nil {
		compareSIDs(t, "GroupSID", got.groupSID, want.groupSID)
	}

	// Compare DACL
	if (got.dacl == nil) != (want.dacl == nil) {
		t.Errorf("DACL presence mismatch: got %v, want %v", got.dacl != nil, want.dacl != nil)
		t.FailNow()
		return
	} else if got.dacl != nil {
		compareACLs(t, "DACL", got.dacl, want.dacl)
	}

	// Compare SACL
	if (got.sacl == nil) != (want.sacl == nil) {
		t.Errorf("SACL presence mismatch: got %v, want %v", got.sacl != nil, want.sacl != nil)
		t.FailNow()
		return
	} else if got.sacl != nil {
		compareACLs(t, "SACL", got.sacl, want.sacl)
	}
}

// Helper function to compare SID fields
func compareSIDs(t *testing.T, prefix string, got, want *sid) {
	t.Helper()

	if got.revision != want.revision {
		t.Errorf("%s.Revision = %v, want %v", prefix, got.revision, want.revision)
		t.FailNow()
		return
	}

	if got.identifierAuthority != want.identifierAuthority {
		t.Errorf("%s.IdentifierAuthority = %v, want %v", prefix, got.identifierAuthority, want.identifierAuthority)
		t.FailNow()
		return
	}

	if len(got.subAuthority) != len(want.subAuthority) {
		t.Errorf("%s.SubAuthority length = %v, want %v\nwant: %s\ngot : %s", prefix, len(got.subAuthority), len(want.subAuthority), want.String(), got.String())
		t.FailNow()
		return
	}

	for i, sub := range got.subAuthority {
		if sub != want.subAuthority[i] {
			t.Errorf("%s.SubAuthority[%d] = %v, want %v", prefix, i, sub, want.subAuthority[i])
			t.FailNow()
			return
		}
	}
}
