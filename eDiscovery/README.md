# Purview eDiscovery Search & Export Tools

Professional PowerShell tools for managing Microsoft Purview eDiscovery searches and exports. Two authentication modes available: App-only (service principal) and Delegated (user sign-in).

**Developer**: Dr Muataz Awad

---

## Scripts Overview

### 1. **Invoke-eDiscoverySearchExport-AppOnly.ps1**
Service principal authentication (automated/unattended scenarios)

### 2. **Invoke-eDiscoverySearchExport-Delegated.ps1**
User authentication via browser sign-in (interactive scenarios)

---

## Prerequisites - App-Only Authentication

### Step 1: Create Service Principal in Azure AD

1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to **Azure Active Directory** → **App registrations** → **New registration**
3. Enter app name (e.g., `eDiscovery-SearchExport-Service`)
4. Select **Accounts in this organizational directory only**
5. Click **Register**

### Step 2: Generate Client Secret

1. In the app registration, go to **Certificates & secrets**
2. Click **New client secret**
3. Set expiration (recommended: 12 months)
4. Copy the **Value** (you won't see it again)
5. Copy the **Secret ID** as backup reference

### Step 3: Grant Microsoft Graph Permissions

1. In the app registration, go to **API permissions**
2. Click **Add a permission** → **Microsoft Graph** → **Application permissions**
3. Search for and add these permissions:
   - `SecurityEvents.Read.All` - Read security events (eDiscovery operations)
   - `ediscovery.Read.All` - Read eDiscovery cases and searches (if available)
   - `Directory.Read.All` - Read directory for user information

4. Click **Grant admin consent** (requires Global Admin)

### Step 4: Add App to Purview eDiscovery Role Group (Required)

> **This step is mandatory.** Microsoft Graph API permissions alone are not sufficient for app-only access to Purview eDiscovery. The service principal must also be a member of the **eDiscovery Managers** role group via Exchange Online. Without this, all API calls return `401 Unauthorized`.

Run the following as a **Global Administrator** or **Exchange Administrator**:

```powershell
# Install the Exchange Online module if needed
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force

# Connect to the compliance/security endpoint
Connect-IPPSSession

# Replace with your app's ClientId (Application ID) and Entra ID Service Principal Object ID
$ClientId            = "<your-ClientId-GUID>"
$ServicePrincipalId  = "<your-ServicePrincipal-ObjectId-GUID>"

# Create the Exchange service principal that links to your Entra ID app
New-ServicePrincipal -AppId $ClientId -ObjectId $ServicePrincipalId -DisplayName "eDiscovery-SearchExport-Service"

# Add the service principal to the eDiscovery Manager role group
Add-RoleGroupMember -Identity "eDiscoveryManager" -Member $ServicePrincipalId

# Add the service principal as an eDiscovery Administrator
Add-eDiscoveryCaseAdmin -User $ServicePrincipalId

# Verify membership
Get-RoleGroupMember -Identity "eDiscoveryManager"
Get-eDiscoveryCaseAdmin
```

> To find the value for `$ServicePrincipalId` (Enterprise Application Object ID):
> 1. Go to Azure Portal → **Microsoft Entra ID** → **Enterprise applications**.
> 2. Search for your app (example: **eDiscovery-SearchExport-Service**) and open it.
> 3. On **Overview**, copy **Object ID**.
>
> Use this Enterprise Application **Object ID** in `New-ServicePrincipal`, `Add-RoleGroupMember`, and `Add-eDiscoveryCaseAdmin`.
> Do **not** use the **Object ID** from **App registrations** for these three commands.

### Step 5: Collect Credentials

From the app registration **Overview** page, copy:
- **Tenant ID** (Directory ID)
- **Client ID** (Application ID)
- **Client Secret** (generated in Step 2)

### Step 6: Create Configuration File (Optional)

**⚠️ Security Warning**: Storing secrets in plain text files is not recommended for production.

For **development/testing only**, you can create `Invoke-eDiscoverySearchExport-AppOnly.config.json`:
- Never store in version control
- Restrict file permissions to authorized users
- Use Azure Key Vault for production environments

Alternatively, use command-line parameters or interactive prompts to avoid storing secrets on disk.

### Step 7: Install Microsoft Graph Module

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

### Running the App-Only Script

**Option A: With config file** (recommended)
```powershell
.\Invoke-eDiscoverySearchExport-AppOnly.ps1
```
Automatically loads credentials from `Invoke-eDiscoverySearchExport-AppOnly.config.json`

**Option B: With command-line parameters**
```powershell
.\Invoke-eDiscoverySearchExport-AppOnly.ps1 `
    -TenantId "<your-azure-ad-directory-id>" `
    -ClientId "<your-app-registration-id>" `
    -ClientSecret "<your-client-secret>"
```

**Option C: Interactive prompts**
```powershell
.\Invoke-eDiscoverySearchExport-AppOnly.ps1
```
If credentials are not in config or parameters, you'll be prompted to enter them.

---

## Prerequisites - Delegated Authentication

### Step 1: User Permissions

Your user account must have one of these roles in the Microsoft 365 admin center:
- **eDiscovery Manager** (recommended for most users)
- **eDiscovery Administrator**
- **Global Administrator**
- **Security Administrator**

To assign roles:
1. Go to [Microsoft 365 Admin Center](https://admin.microsoft.com)
2. Navigate to **Roles** → **Role assignments**
3. Search for user and assign appropriate eDiscovery role

### Step 2: Install Microsoft Graph Module

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

### Step 3: Grant Required Scopes

The script automatically requests these scopes during sign-in:
- `eDiscovery.Read.All` - Read eDiscovery cases and searches
- `offline_access` - Keep you signed in

Accept the permission prompt when the browser opens.

### Running the Delegated Script

```powershell
.\Invoke-eDiscoverySearchExport-Delegated.ps1
```

A browser window opens for you to sign in. Accept the permission scopes, then the script executes in your user context.

---

## Features Available

### Search Explorer
- View all searches in a case
- Display item counts and sizes
- Show search status and last modified date

### Export Operations
- List all export jobs for a case
- Display export status and creation date
- Show export metadata and creator information

### Export Files
- Download export files to local disk
- Automatic filename collision handling
- Real-time download progress and file size display

### Dashboard Statistics
- Total items indexed across all searches
- Total case size in MB
- Latest export timestamp

---

## Troubleshooting

### App-Only Authentication Issues

**Error: "Failed to connect app-only"**
- Verify ClientId, ClientSecret, and TenantId are correct
- Check that the service principal has required permissions granted
- Verify the client secret hasn't expired

**Error: "Invalid scope"**
- Ensure Microsoft Graph permissions are granted in Azure AD
- Global Admin must click "Grant admin consent"
- Wait 5 minutes after granting permissions for caching to clear

**Config file not found**
- Ensure `Invoke-eDiscoverySearchExport-AppOnly.config.json` is in the same directory as the script
- Use absolute path if running from a different location

### Delegated Authentication Issues

**Error: "Browser didn't open"**
- Firewall may block browser launch; sign in manually or disable firewall
- Ensure you have internet connectivity

**Error: "eDiscovery.Read.All not granted"**
- Check your user has eDiscovery Manager or higher role
- Global Admin must grant "eDiscovery.Read.All" scope to application
- Sign out and sign in again

### No Cases Found

**Verify**:
- You have at least one eDiscovery case created in Microsoft 365
- Your user account has read access to the case
- You're signed in with correct credentials

---

## Security Best Practices

### App-Only Authentication

1. **Secret Rotation**: Rotate client secret every 12 months
2. **Least Privilege**: Create service principal with only required permissions
3. **Network Security**: Run from trusted networks only
4. **Audit Logging**: Monitor service principal sign-in activity in Azure AD audit logs
5. **Key Vault**: Store credentials in Azure Key Vault for production
6. **File Permissions**: Restrict config file read access to authorized users

### Delegated Authentication

1. **Account Security**: Use strong password and MFA (multi-factor authentication)
2. **Session Duration**: Sign out when not actively using the script
3. **Audit**: eDiscovery operations are logged in the audit log
4. **Conditional Access**: Your organization's Conditional Access policies apply

---

## Module Dependencies

Both scripts require:
- **PowerShell 5.1** or higher
- **Microsoft.Graph.Authentication** module

Install with:
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

---

## Configuration File Format

**Invoke-eDiscoverySearchExport-AppOnly.config.json** (Optional - development/testing only)

For production, use **Azure Key Vault** or pass credentials via command-line parameters/prompts instead.

JSON structure (if using file):
```json
{
    "TenantId": "<your-azure-ad-directory-id>",
    "ClientId": "<your-app-registration-id>",
    "ClientSecret": "<your-client-secret>"
}
```

Replace values:
- **TenantId**: Found in Azure AD → Overview → Tenant ID
- **ClientId**: Found in App Registration → Overview → Application (client) ID  
- **ClientSecret**: Value copied from Certificates & secrets (not the Secret ID)

**Never share this file or commit to version control.**

---

## API Documentation References

- [Microsoft Graph eDiscovery Cases](https://docs.microsoft.com/en-us/graph/api/resources/security-ediscoverycase)
- [Microsoft Graph Searches](https://docs.microsoft.com/en-us/graph/api/resources/security-ediscoverysearch)
- [Microsoft Graph Operations](https://docs.microsoft.com/en-us/graph/api/resources/security-caseoperation)
- [Microsoft Graph Authentication](https://docs.microsoft.com/en-us/graph/auth)

---

## Support & Feedback

For issues or suggestions, review the script documentation at the top of each `.ps1` file.

**Last Updated**: June 20, 2026
