# Plan B: .NET Recipe App MVP

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a functional .NET 8 Razor Pages recipe manager with basic CRUD, SQLite persistence, and seed data. This is the primary demo app for the April 2, 2026 presentation on Claude Agent Dispatch.

**Architecture:** .NET 8 Razor Pages app with Entity Framework Core and SQLite. Minimal design — just enough to look like a real app. The agent will later add features (dark mode, ratings, favorites, search) to this app during the demo issue staging phase (Plan D).

**Tech Stack:** .NET 8, Razor Pages, Entity Framework Core, SQLite, Bootstrap 5 (comes with default template)

**Machine:** Windows — .NET 8 SDK required. The repo was created in Plan A at `jnurre64/recipe-manager-demo`.

**Prerequisites:**
- .NET 8 SDK installed (`dotnet --version` should show 8.x)
- Git configured
- Repo cloned: `git clone https://github.com/jnurre64/recipe-manager-demo.git`
- Plan A completed (repo exists on GitHub with agent-dispatch config)

**Design spec:** `docs/superpowers/specs/2026-03-26-presentation-demo-design.md` in the claude-agent-dispatch repo (branch `presentation/demo-prep`)

---

## File Structure

```
recipe-manager-demo/
├── RecipeManager/                    # Main web project
│   ├── Program.cs                    # App startup, DI, middleware
│   ├── RecipeManager.csproj          # Project file with EF Core + SQLite packages
│   ├── Data/
│   │   ├── RecipeDbContext.cs         # EF Core DbContext
│   │   └── SeedData.cs               # Initial recipe data
│   ├── Models/
│   │   └── Recipe.cs                 # Recipe entity
│   ├── Pages/
│   │   ├── Recipes/
│   │   │   ├── Index.cshtml          # List all recipes
│   │   │   ├── Index.cshtml.cs       # List page model
│   │   │   ├── Details.cshtml        # View single recipe
│   │   │   ├── Details.cshtml.cs     # Details page model
│   │   │   ├── Create.cshtml         # Add new recipe form
│   │   │   ├── Create.cshtml.cs      # Create page model
│   │   │   ├── Edit.cshtml           # Edit recipe form
│   │   │   ├── Edit.cshtml.cs        # Edit page model
│   │   │   ├── Delete.cshtml         # Delete confirmation
│   │   │   └── Delete.cshtml.cs      # Delete page model
│   │   ├── _Layout.cshtml            # Shared layout (modified for nav)
│   │   └── Index.cshtml              # Home page (redirect to recipes)
│   └── wwwroot/
│       └── css/
│           └── site.css              # Custom styles
├── RecipeManager.Tests/              # Test project
│   ├── RecipeManager.Tests.csproj    # Test project file
│   └── RecipeModelTests.cs           # Basic model tests
└── RecipeManager.sln                 # Solution file
```

---

### Task 1: Create the .NET solution and project

**Files:**
- Create: `RecipeManager.sln`
- Create: `RecipeManager/RecipeManager.csproj`
- Create: `RecipeManager/Program.cs`

- [ ] **Step 1: Create the solution and web project**

```bash
cd ~/repos/recipe-manager-demo
dotnet new sln -n RecipeManager
dotnet new webapp -n RecipeManager -o RecipeManager
dotnet sln add RecipeManager/RecipeManager.csproj
```

- [ ] **Step 2: Add EF Core and SQLite packages**

```bash
cd RecipeManager
dotnet add package Microsoft.EntityFrameworkCore.Sqlite
dotnet add package Microsoft.EntityFrameworkCore.Design
dotnet add package Microsoft.EntityFrameworkCore.Tools
cd ..
```

- [ ] **Step 3: Verify it builds and runs**

```bash
dotnet build
dotnet run --project RecipeManager
```

Visit `https://localhost:5001` (or the port shown) — you should see the default Razor Pages welcome page.

- [ ] **Step 4: Create a test project**

```bash
dotnet new xunit -n RecipeManager.Tests -o RecipeManager.Tests
dotnet sln add RecipeManager.Tests/RecipeManager.Tests.csproj
dotnet add RecipeManager.Tests/RecipeManager.Tests.csproj reference RecipeManager/RecipeManager.csproj
```

- [ ] **Step 5: Verify tests run**

```bash
dotnet test
```

Expected: 1 default test passes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: initialize .NET 8 solution with Razor Pages and xUnit test project"
git push
```

---

### Task 2: Create the Recipe model and DbContext

**Files:**
- Create: `RecipeManager/Models/Recipe.cs`
- Create: `RecipeManager/Data/RecipeDbContext.cs`
- Modify: `RecipeManager/Program.cs`

- [ ] **Step 1: Write a failing test for the Recipe model**

Create `RecipeManager.Tests/RecipeModelTests.cs`:

```csharp
using RecipeManager.Models;

namespace RecipeManager.Tests;

public class RecipeModelTests
{
    [Fact]
    public void Recipe_HasRequiredProperties()
    {
        var recipe = new Recipe
        {
            Id = 1,
            Name = "Test Recipe",
            Description = "A test",
            Ingredients = "Flour, Sugar",
            Instructions = "Mix and bake"
        };

        Assert.Equal(1, recipe.Id);
        Assert.Equal("Test Recipe", recipe.Name);
        Assert.Equal("A test", recipe.Description);
        Assert.Equal("Flour, Sugar", recipe.Ingredients);
        Assert.Equal("Mix and bake", recipe.Instructions);
    }

    [Fact]
    public void Recipe_CreatedAt_DefaultsToNow()
    {
        var before = DateTime.UtcNow;
        var recipe = new Recipe();
        var after = DateTime.UtcNow;

        Assert.InRange(recipe.CreatedAt, before, after);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
dotnet test
```

Expected: FAIL — `Recipe` type does not exist.

- [ ] **Step 3: Create the Recipe model**

Create `RecipeManager/Models/Recipe.cs`:

```csharp
using System.ComponentModel.DataAnnotations;

namespace RecipeManager.Models;

public class Recipe
{
    public int Id { get; set; }

    [Required]
    [StringLength(200)]
    public string Name { get; set; } = string.Empty;

    [StringLength(500)]
    public string Description { get; set; } = string.Empty;

    [Required]
    public string Ingredients { get; set; } = string.Empty;

    [Required]
    public string Instructions { get; set; } = string.Empty;

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dotnet test
```

Expected: 2 passed.

- [ ] **Step 5: Create the DbContext**

Create `RecipeManager/Data/RecipeDbContext.cs`:

```csharp
using Microsoft.EntityFrameworkCore;
using RecipeManager.Models;

namespace RecipeManager.Data;

public class RecipeDbContext : DbContext
{
    public RecipeDbContext(DbContextOptions<RecipeDbContext> options) : base(options) { }

    public DbSet<Recipe> Recipes => Set<Recipe>();
}
```

- [ ] **Step 6: Register the DbContext in Program.cs**

In `RecipeManager/Program.cs`, add the using statements and DbContext registration. Replace the file contents with:

```csharp
using Microsoft.EntityFrameworkCore;
using RecipeManager.Data;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddDbContext<RecipeDbContext>(options =>
    options.UseSqlite("Data Source=recipes.db"));

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseAuthorization();
app.MapRazorPages();

// Ensure database is created
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<RecipeDbContext>();
    db.Database.EnsureCreated();
}

app.Run();
```

- [ ] **Step 7: Verify build succeeds**

```bash
dotnet build
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add Recipe model and EF Core DbContext with SQLite"
git push
```

---

### Task 3: Add seed data

**Files:**
- Create: `RecipeManager/Data/SeedData.cs`
- Modify: `RecipeManager/Program.cs`

- [ ] **Step 1: Create the seed data class**

Create `RecipeManager/Data/SeedData.cs`:

```csharp
using RecipeManager.Models;

namespace RecipeManager.Data;

public static class SeedData
{
    public static void Initialize(RecipeDbContext context)
    {
        if (context.Recipes.Any())
            return;

        context.Recipes.AddRange(
            new Recipe
            {
                Name = "Classic Pancakes",
                Description = "Fluffy buttermilk pancakes perfect for a weekend breakfast.",
                Ingredients = "2 cups flour\n1 egg\n1.5 cups buttermilk\n2 tbsp sugar\n1 tsp baking powder\n0.5 tsp baking soda\n2 tbsp melted butter",
                Instructions = "1. Mix dry ingredients in a bowl.\n2. Whisk egg, buttermilk, and melted butter.\n3. Combine wet and dry ingredients — don't overmix.\n4. Cook on a buttered griddle at medium heat until bubbles form, then flip.\n5. Serve with maple syrup."
            },
            new Recipe
            {
                Name = "Garlic Butter Pasta",
                Description = "A simple weeknight pasta with garlic, butter, and parmesan.",
                Ingredients = "1 lb spaghetti\n4 cloves garlic, minced\n4 tbsp butter\n0.5 cup parmesan\nRed pepper flakes\nFresh parsley\nSalt and pepper",
                Instructions = "1. Cook pasta according to package directions, reserve 1 cup pasta water.\n2. Melt butter in a pan, add garlic and cook until fragrant (1 min).\n3. Toss pasta with garlic butter, adding pasta water as needed.\n4. Top with parmesan, parsley, and red pepper flakes."
            },
            new Recipe
            {
                Name = "Chicken Stir-Fry",
                Description = "Quick and colorful chicken stir-fry with vegetables.",
                Ingredients = "2 chicken breasts, sliced\n1 bell pepper, sliced\n1 cup broccoli florets\n2 tbsp soy sauce\n1 tbsp sesame oil\n1 tbsp cornstarch\n2 cloves garlic\n1 tsp ginger\nRice for serving",
                Instructions = "1. Mix soy sauce, sesame oil, and cornstarch for the sauce.\n2. Stir-fry chicken in a hot pan until cooked through. Remove.\n3. Stir-fry vegetables for 3-4 minutes.\n4. Add chicken back, pour sauce over, toss until coated.\n5. Serve over rice."
            },
            new Recipe
            {
                Name = "Caesar Salad",
                Description = "Classic Caesar salad with homemade croutons.",
                Ingredients = "1 head romaine lettuce\n0.5 cup parmesan shaved\n1 cup croutons\n2 tbsp Caesar dressing\n1 lemon\nBlack pepper",
                Instructions = "1. Wash and chop romaine lettuce.\n2. Toss with Caesar dressing.\n3. Top with croutons and shaved parmesan.\n4. Squeeze lemon over top and add fresh black pepper."
            },
            new Recipe
            {
                Name = "Banana Bread",
                Description = "Moist banana bread — the riper the bananas, the better.",
                Ingredients = "3 ripe bananas\n1/3 cup melted butter\n3/4 cup sugar\n1 egg\n1 tsp vanilla\n1 tsp baking soda\n1.5 cups flour\nPinch of salt",
                Instructions = "1. Preheat oven to 350°F. Grease a loaf pan.\n2. Mash bananas, mix in melted butter.\n3. Add sugar, egg, and vanilla.\n4. Stir in baking soda and salt, then fold in flour.\n5. Pour into pan and bake 55-65 minutes until a toothpick comes out clean."
            }
        );

        context.SaveChanges();
    }
}
```

- [ ] **Step 2: Call the seed method in Program.cs**

In `RecipeManager/Program.cs`, update the database initialization section (replace the existing `EnsureCreated` block):

```csharp
// Ensure database is created and seeded
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<RecipeDbContext>();
    db.Database.EnsureCreated();
    SeedData.Initialize(db);
}
```

- [ ] **Step 3: Verify the app starts and seeds data**

```bash
dotnet run --project RecipeManager
```

No errors on startup. (We can't see the data yet — no UI for recipes.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add seed data with 5 sample recipes"
git push
```

---

### Task 4: Scaffold CRUD Razor Pages

**Files:**
- Create: `RecipeManager/Pages/Recipes/Index.cshtml` + `.cs`
- Create: `RecipeManager/Pages/Recipes/Details.cshtml` + `.cs`
- Create: `RecipeManager/Pages/Recipes/Create.cshtml` + `.cs`
- Create: `RecipeManager/Pages/Recipes/Edit.cshtml` + `.cs`
- Create: `RecipeManager/Pages/Recipes/Delete.cshtml` + `.cs`

- [ ] **Step 1: Create the Recipes folder**

```bash
mkdir -p RecipeManager/Pages/Recipes
```

- [ ] **Step 2: Create the List page (Index)**

Create `RecipeManager/Pages/Recipes/Index.cshtml.cs`:

```csharp
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;
using RecipeManager.Data;
using RecipeManager.Models;

namespace RecipeManager.Pages.Recipes;

public class IndexModel : PageModel
{
    private readonly RecipeDbContext _context;

    public IndexModel(RecipeDbContext context)
    {
        _context = context;
    }

    public IList<Recipe> Recipes { get; set; } = new List<Recipe>();

    public async Task OnGetAsync()
    {
        Recipes = await _context.Recipes
            .OrderByDescending(r => r.CreatedAt)
            .ToListAsync();
    }
}
```

Create `RecipeManager/Pages/Recipes/Index.cshtml`:

```html
@page
@model RecipeManager.Pages.Recipes.IndexModel
@{
    ViewData["Title"] = "Recipes";
}

<div class="d-flex justify-content-between align-items-center mb-4">
    <h1>Recipes</h1>
    <a asp-page="Create" class="btn btn-primary">Add Recipe</a>
</div>

@if (!Model.Recipes.Any())
{
    <p class="text-muted">No recipes yet. Add your first one!</p>
}
else
{
    <div class="row row-cols-1 row-cols-md-2 row-cols-lg-3 g-4">
        @foreach (var recipe in Model.Recipes)
        {
            <div class="col">
                <div class="card h-100">
                    <div class="card-body">
                        <h5 class="card-title">@recipe.Name</h5>
                        <p class="card-text text-muted">@recipe.Description</p>
                    </div>
                    <div class="card-footer bg-transparent">
                        <a asp-page="Details" asp-route-id="@recipe.Id" class="btn btn-sm btn-outline-primary">View</a>
                        <a asp-page="Edit" asp-route-id="@recipe.Id" class="btn btn-sm btn-outline-secondary">Edit</a>
                        <a asp-page="Delete" asp-route-id="@recipe.Id" class="btn btn-sm btn-outline-danger">Delete</a>
                    </div>
                </div>
            </div>
        }
    </div>
}
```

- [ ] **Step 3: Create the Details page**

Create `RecipeManager/Pages/Recipes/Details.cshtml.cs`:

```csharp
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RecipeManager.Data;
using RecipeManager.Models;

namespace RecipeManager.Pages.Recipes;

public class DetailsModel : PageModel
{
    private readonly RecipeDbContext _context;

    public DetailsModel(RecipeDbContext context)
    {
        _context = context;
    }

    public Recipe Recipe { get; set; } = default!;

    public async Task<IActionResult> OnGetAsync(int id)
    {
        var recipe = await _context.Recipes.FindAsync(id);
        if (recipe == null)
            return NotFound();

        Recipe = recipe;
        return Page();
    }
}
```

Create `RecipeManager/Pages/Recipes/Details.cshtml`:

```html
@page "{id:int}"
@model RecipeManager.Pages.Recipes.DetailsModel
@{
    ViewData["Title"] = Model.Recipe.Name;
}

<h1>@Model.Recipe.Name</h1>
<p class="text-muted">@Model.Recipe.Description</p>

<div class="row mt-4">
    <div class="col-md-6">
        <h4>Ingredients</h4>
        <ul class="list-group">
            @foreach (var ingredient in Model.Recipe.Ingredients.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                <li class="list-group-item">@ingredient.Trim()</li>
            }
        </ul>
    </div>
    <div class="col-md-6">
        <h4>Instructions</h4>
        <ol class="list-group list-group-numbered">
            @foreach (var step in Model.Recipe.Instructions.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var text = System.Text.RegularExpressions.Regex.Replace(step.Trim(), @"^\d+\.\s*", "");
                <li class="list-group-item">@text</li>
            }
        </ol>
    </div>
</div>

<div class="mt-4">
    <a asp-page="Edit" asp-route-id="@Model.Recipe.Id" class="btn btn-secondary">Edit</a>
    <a asp-page="Index" class="btn btn-outline-secondary">Back to Recipes</a>
</div>
```

- [ ] **Step 4: Create the Create page**

Create `RecipeManager/Pages/Recipes/Create.cshtml.cs`:

```csharp
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RecipeManager.Data;
using RecipeManager.Models;

namespace RecipeManager.Pages.Recipes;

public class CreateModel : PageModel
{
    private readonly RecipeDbContext _context;

    public CreateModel(RecipeDbContext context)
    {
        _context = context;
    }

    [BindProperty]
    public Recipe Recipe { get; set; } = new();

    public IActionResult OnGet()
    {
        return Page();
    }

    public async Task<IActionResult> OnPostAsync()
    {
        if (!ModelState.IsValid)
            return Page();

        _context.Recipes.Add(Recipe);
        await _context.SaveChangesAsync();
        return RedirectToPage("Index");
    }
}
```

Create `RecipeManager/Pages/Recipes/Create.cshtml`:

```html
@page
@model RecipeManager.Pages.Recipes.CreateModel
@{
    ViewData["Title"] = "Add Recipe";
}

<h1>Add Recipe</h1>

<form method="post" class="mt-3" style="max-width: 600px;">
    <div asp-validation-summary="All" class="text-danger"></div>

    <div class="mb-3">
        <label asp-for="Recipe.Name" class="form-label"></label>
        <input asp-for="Recipe.Name" class="form-control" />
        <span asp-validation-for="Recipe.Name" class="text-danger"></span>
    </div>

    <div class="mb-3">
        <label asp-for="Recipe.Description" class="form-label"></label>
        <textarea asp-for="Recipe.Description" class="form-control" rows="2"></textarea>
    </div>

    <div class="mb-3">
        <label asp-for="Recipe.Ingredients" class="form-label"></label>
        <textarea asp-for="Recipe.Ingredients" class="form-control" rows="5" placeholder="One ingredient per line"></textarea>
        <span asp-validation-for="Recipe.Ingredients" class="text-danger"></span>
    </div>

    <div class="mb-3">
        <label asp-for="Recipe.Instructions" class="form-label"></label>
        <textarea asp-for="Recipe.Instructions" class="form-control" rows="5" placeholder="One step per line"></textarea>
        <span asp-validation-for="Recipe.Instructions" class="text-danger"></span>
    </div>

    <button type="submit" class="btn btn-primary">Save Recipe</button>
    <a asp-page="Index" class="btn btn-outline-secondary">Cancel</a>
</form>
```

- [ ] **Step 5: Create the Edit page**

Create `RecipeManager/Pages/Recipes/Edit.cshtml.cs`:

```csharp
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RecipeManager.Data;
using RecipeManager.Models;

namespace RecipeManager.Pages.Recipes;

public class EditModel : PageModel
{
    private readonly RecipeDbContext _context;

    public EditModel(RecipeDbContext context)
    {
        _context = context;
    }

    [BindProperty]
    public Recipe Recipe { get; set; } = default!;

    public async Task<IActionResult> OnGetAsync(int id)
    {
        var recipe = await _context.Recipes.FindAsync(id);
        if (recipe == null)
            return NotFound();

        Recipe = recipe;
        return Page();
    }

    public async Task<IActionResult> OnPostAsync()
    {
        if (!ModelState.IsValid)
            return Page();

        _context.Attach(Recipe).State = Microsoft.EntityFrameworkCore.EntityState.Modified;
        await _context.SaveChangesAsync();
        return RedirectToPage("Index");
    }
}
```

Create `RecipeManager/Pages/Recipes/Edit.cshtml`:

```html
@page "{id:int}"
@model RecipeManager.Pages.Recipes.EditModel
@{
    ViewData["Title"] = "Edit Recipe";
}

<h1>Edit Recipe</h1>

<form method="post" class="mt-3" style="max-width: 600px;">
    <input type="hidden" asp-for="Recipe.Id" />
    <input type="hidden" asp-for="Recipe.CreatedAt" />
    <div asp-validation-summary="All" class="text-danger"></div>

    <div class="mb-3">
        <label asp-for="Recipe.Name" class="form-label"></label>
        <input asp-for="Recipe.Name" class="form-control" />
        <span asp-validation-for="Recipe.Name" class="text-danger"></span>
    </div>

    <div class="mb-3">
        <label asp-for="Recipe.Description" class="form-label"></label>
        <textarea asp-for="Recipe.Description" class="form-control" rows="2"></textarea>
    </div>

    <div class="mb-3">
        <label asp-for="Recipe.Ingredients" class="form-label"></label>
        <textarea asp-for="Recipe.Ingredients" class="form-control" rows="5"></textarea>
        <span asp-validation-for="Recipe.Ingredients" class="text-danger"></span>
    </div>

    <div class="mb-3">
        <label asp-for="Recipe.Instructions" class="form-label"></label>
        <textarea asp-for="Recipe.Instructions" class="form-control" rows="5"></textarea>
        <span asp-validation-for="Recipe.Instructions" class="text-danger"></span>
    </div>

    <button type="submit" class="btn btn-primary">Save Changes</button>
    <a asp-page="Index" class="btn btn-outline-secondary">Cancel</a>
</form>
```

- [ ] **Step 6: Create the Delete page**

Create `RecipeManager/Pages/Recipes/Delete.cshtml.cs`:

```csharp
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RecipeManager.Data;
using RecipeManager.Models;

namespace RecipeManager.Pages.Recipes;

public class DeleteModel : PageModel
{
    private readonly RecipeDbContext _context;

    public DeleteModel(RecipeDbContext context)
    {
        _context = context;
    }

    [BindProperty]
    public Recipe Recipe { get; set; } = default!;

    public async Task<IActionResult> OnGetAsync(int id)
    {
        var recipe = await _context.Recipes.FindAsync(id);
        if (recipe == null)
            return NotFound();

        Recipe = recipe;
        return Page();
    }

    public async Task<IActionResult> OnPostAsync(int id)
    {
        var recipe = await _context.Recipes.FindAsync(id);
        if (recipe != null)
        {
            _context.Recipes.Remove(recipe);
            await _context.SaveChangesAsync();
        }
        return RedirectToPage("Index");
    }
}
```

Create `RecipeManager/Pages/Recipes/Delete.cshtml`:

```html
@page "{id:int}"
@model RecipeManager.Pages.Recipes.DeleteModel
@{
    ViewData["Title"] = "Delete Recipe";
}

<h1>Delete Recipe</h1>

<div class="alert alert-warning mt-3">
    <strong>Are you sure?</strong> This will permanently delete <strong>@Model.Recipe.Name</strong>.
</div>

<dl class="row">
    <dt class="col-sm-3">Description</dt>
    <dd class="col-sm-9">@Model.Recipe.Description</dd>
</dl>

<form method="post" asp-route-id="@Model.Recipe.Id">
    <button type="submit" class="btn btn-danger">Delete</button>
    <a asp-page="Index" class="btn btn-outline-secondary">Cancel</a>
</form>
```

- [ ] **Step 7: Update the home page to redirect to recipes**

Replace the content of `RecipeManager/Pages/Index.cshtml`:

```html
@page
@model IndexModel
@{
    Response.Redirect("/Recipes");
}
```

- [ ] **Step 8: Update the navigation in _Layout.cshtml**

In `RecipeManager/Pages/Shared/_Layout.cshtml`, find the navbar links section and update it to include a "Recipes" link. Find the `<ul class="navbar-nav">` section and replace it with:

```html
<ul class="navbar-nav flex-grow-1">
    <li class="nav-item">
        <a class="nav-link text-dark" asp-area="" asp-page="/Recipes/Index">Recipes</a>
    </li>
</ul>
```

Also update the brand/title in the navbar from the default to:

```html
<a class="navbar-brand" asp-area="" asp-page="/Recipes/Index">Recipe Manager</a>
```

- [ ] **Step 9: Verify the full app works**

```bash
# Delete old database if it exists
rm -f RecipeManager/recipes.db
dotnet run --project RecipeManager
```

Visit `https://localhost:5001` — should redirect to `/Recipes` showing 5 seed recipes as cards. Test:
- Click "View" on a recipe — shows ingredients and instructions
- Click "Add Recipe" — fill form, save, see it in the list
- Click "Edit" on a recipe — modify, save
- Click "Delete" on a recipe — confirm, recipe removed

- [ ] **Step 10: Run tests**

```bash
dotnet test
```

Expected: 2 tests pass (from Task 2).

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: add CRUD Razor Pages for recipes with Bootstrap cards"
git push
```

---

### Task 5: Add .gitignore entries for SQLite and ensure clean state

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add SQLite database to .gitignore**

Append to `.gitignore`:

```
# SQLite databases
*.db
*.db-shm
*.db-wal
```

- [ ] **Step 2: Remove the database from tracking if it was committed**

```bash
git rm --cached RecipeManager/recipes.db 2>/dev/null || true
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: add SQLite database to .gitignore"
git push
```

---

### Task 6: Final verification

- [ ] **Step 1: Clean build from scratch**

```bash
dotnet clean
dotnet build
dotnet test
```

Expected: Build succeeds, 2 tests pass.

- [ ] **Step 2: Run and verify all CRUD operations**

```bash
rm -f RecipeManager/recipes.db
dotnet run --project RecipeManager
```

Walk through: list, view, create, edit, delete. All should work.

- [ ] **Step 3: Verify the app looks presentable**

The default Bootstrap 5 template should give a clean, professional look. The recipe cards on the list page and the detail/form pages should all be readable and look decent on a screenshare. If anything looks rough, minor CSS tweaks in `wwwroot/css/site.css` can be made.

This completes the MVP. The agent will add features (dark mode, ratings, favorites, search) to this app during Plan D (issue staging).
